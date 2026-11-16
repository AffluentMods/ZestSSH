import 'dart:convert';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart'
    show SyncException, SyncConflictException, SyncService;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/sync/sync_failure.dart';

/// Cloud-sync backend that stores the manifest in the user's Google Drive,
/// inside the hidden **app-data folder** (`drive.appdata` scope). ZestSSH can
/// only see the single file it creates there - never the user's other Drive
/// files - and the file is invisible in the normal Drive UI.
///
/// Auth on a phone reuses the `google_sign_in` plugin already in the app. On
/// a computer that plugin does not exist (Windows, Linux) or is not set up
/// (macOS), and every call to it failed with a MissingPluginException; there
/// the sign-in is the browser flow in `google_desktop_oauth.dart`.
///
/// Optimistic locking relies on the version-compare CAS in
/// [DumbStoreSyncBackend] (Drive's conditional-request support is
/// inconsistent across clients); this is safe because Drive sync is
/// effectively single-user.
class GoogleDriveSyncBackend extends DumbStoreSyncBackend {
  /// The one Drive permission this backend asks for: the hidden app-data
  /// folder, which holds only what this app put there.
  static const appDataScope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _appDataScope = appDataScope;
  static const _apiBase = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';

  GoogleSignIn? _signIn;
  GoogleSignInAccount? _account;

  /// [desktopOAuth], [useDesktopFlow] and [client] are for tests; the app
  /// passes none of them.
  GoogleDriveSyncBackend({
    GoogleDesktopOAuth? desktopOAuth,
    bool? useDesktopFlow,
    http.Client? client,
  })  : _oauth = desktopOAuth ?? GoogleDesktopOAuth.instance,
        _desktop = useDesktopFlow ?? GoogleDesktopOAuth.usedOnThisPlatform,
        _injectedClient = client;

  final GoogleDesktopOAuth _oauth;
  final bool _desktop;
  final http.Client? _injectedClient;
  String? _desktopEmail;

  /// Whether Google Drive sync can be used on this device with this build:
  /// always on a phone; on a computer only when the build was given the
  /// desktop sign-in client.
  static bool get availableHere =>
      !GoogleDesktopOAuth.usedOnThisPlatform ||
      GoogleDesktopOAuth.instance.isConfigured;

  @override
  SyncBackendKind get kind => SyncBackendKind.googleDrive;

  String? get _email => _desktop ? _desktopEmail : _account?.email;

  @override
  String get displayName =>
      _email != null ? 'Google Drive ($_email)' : 'Google Drive';

  GoogleSignIn get _gsi {
    _signIn ??= GoogleSignIn(scopes: const [_appDataScope]);
    return _signIn!;
  }

  Future<Map<String, String>> _authHeaders() async {
    if (_desktop) {
      try {
        final token = await _oauth.accessToken(const [_appDataScope]);
        _desktopEmail ??= await _oauth.email();
        return {'Authorization': 'Bearer $token'};
      } on GoogleAuthException catch (e) {
        throw SyncException(e.message, detail: e.detail);
      }
    }
    _account ??= await _gsi.signInSilently();
    if (_account == null) {
      throw SyncException(gl10n.googleDriveNotConnected);
    }
    final auth = await _account!.authentication;
    final token = auth.accessToken;
    if (token == null) {
      throw SyncException(gl10n.syncDriveReconnect, detail: 'Google Drive did not return an access token');
    }
    return {'Authorization': 'Bearer $token'};
  }

  // Reused per-instance client (was a fresh, never-closed client per request).
  late final http.Client _client = _injectedClient ?? http.Client();

  /// Hard cap for the small JSON acks Drive returns on list/create/update/
  /// delete - only the media GET can be large (bounded separately).
  static const _ackCap = 1024 * 1024;

  @override
  void dispose() => _client.close();

  // ── checkConnection (interactive) ─────────────────────────────────

  @override
  Future<void> checkConnection() async {
    if (_desktop) {
      try {
        // Already connected here: nothing to ask. Otherwise the browser
        // opens and the person signs in at Google.
        if (await _oauth.isConnected(const [_appDataScope])) {
          _desktopEmail = await _oauth.email();
        } else {
          _desktopEmail = await _oauth.signIn(const [_appDataScope]);
        }
      } on GoogleAuthException catch (e) {
        throw SyncException(e.message, detail: e.detail);
      }
      // A trivial list call confirms the token + scope are usable.
      await _findFileId();
      return;
    }
    try {
      _account = await _gsi.signInSilently() ?? await _gsi.signIn();
    } catch (e) {
      throw SyncException(gl10n.googleDriveSignInFailed, detail: '$e');
    }
    if (_account == null) {
      throw SyncException(gl10n.googleDriveSignInCancelled);
    }
    // A trivial list call confirms the token + scope are usable.
    await _findFileId();
  }

  // ── Store primitives ──────────────────────────────────────────────

  @override
  Future<RawObject?> readObject() async {
    final id = await _findFileId();
    if (id == null) return null;

    final headers = await _authHeaders();
    final request =
        http.Request('GET', Uri.parse('$_apiBase/files/$id?alt=media'));
    request.headers.addAll(headers);
    final response =
        await sendCapped(_client, request, SyncService.maxBlobBytes * 2);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw SyncFailure.storeAnswered(response.statusCode, 'Google Drive download failed: HTTP ${response.statusCode}');
    }
    // Drive has no ETag we can use for If-Match here; the base class does
    // version-compare CAS instead, so etag is intentionally null.
    return RawObject(response.bodyBytes, null);
  }

  @override
  Future<String?> writeObject(
    Uint8List bytes, {
    String? ifMatchEtag,
    bool ifAbsent = false,
  }) async {
    final headers = await _authHeaders();
    final existingId = await _findFileId();

    if (ifAbsent && existingId != null) {
      // Another device created the file between our read and this write.
      throw const SyncConflictException(serverVersion: -1, expectedVersion: -1);
    }

    if (existingId != null) {
      // Update media in place. Route through sendCapped so a hostile response
      // body can't OOM us on a write verb either.
      final request = http.Request(
          'PATCH', Uri.parse('$_uploadBase/files/$existingId?uploadType=media'))
        ..headers.addAll({...headers, 'Content-Type': 'application/json'})
        ..bodyBytes = bytes;
      final response = await sendCapped(_client, request, _ackCap);
      if (response.statusCode != 200) {
        throw SyncFailure.storeAnswered(response.statusCode, 'Google Drive update failed: HTTP ${response.statusCode}');
      }
      return null;
    }

    // Create: multipart (metadata part pins it to the app-data folder).
    final boundary =
        'zestssh_sync_${bytes.length}_${bytes.isEmpty ? 0 : bytes.first}';
    final metadata = jsonEncode({
      'name': DumbStoreSyncBackend.manifestObjectName,
      'parents': ['appDataFolder'],
    });
    final body = <int>[];
    void add(String s) => body.addAll(utf8.encode(s));
    add('--$boundary\r\n');
    add('Content-Type: application/json; charset=UTF-8\r\n\r\n');
    add(metadata);
    add('\r\n--$boundary\r\n');
    add('Content-Type: application/json\r\n\r\n');
    body.addAll(bytes);
    add('\r\n--$boundary--\r\n');

    final request = http.Request(
        'POST', Uri.parse('$_uploadBase/files?uploadType=multipart&fields=id'))
      ..headers.addAll(
          {...headers, 'Content-Type': 'multipart/related; boundary=$boundary'})
      ..bodyBytes = Uint8List.fromList(body);
    final response = await sendCapped(_client, request, _ackCap);
    if (response.statusCode != 200) {
      throw SyncFailure.storeAnswered(response.statusCode, 'Google Drive create failed: HTTP ${response.statusCode}');
    }
    return null;
  }

  @override
  Future<void> deleteObject() async {
    final id = await _findFileId();
    if (id == null) return;
    final headers = await _authHeaders();
    final request = http.Request('DELETE', Uri.parse('$_apiBase/files/$id'))
      ..headers.addAll(headers);
    final response = await sendCapped(_client, request, _ackCap);
    final s = response.statusCode;
    if (s != 204 && s != 200 && s != 404) {
      throw SyncFailure.storeAnswered(s, 'Google Drive delete failed: HTTP $s');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<String?> _findFileId() async {
    final headers = await _authHeaders();
    final q = Uri.encodeComponent(
      "name = '${DumbStoreSyncBackend.manifestObjectName}' and trashed = false",
    );
    // orderBy=createdTime → if two devices raced and created duplicate files,
    // every device deterministically reconciles onto the EARLIEST one instead
    // of picking an arbitrary "first", so they converge rather than ping-pong.
    final uri = Uri.parse(
      '$_apiBase/files?spaces=appDataFolder&q=$q'
      '&orderBy=createdTime&fields=files(id,modifiedTime)',
    );
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await sendCapped(_client, request, _ackCap);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncException(gl10n.syncDriveReconnect, detail: 'Google Drive denied access');
    }
    if (response.statusCode != 200) {
      throw SyncFailure.storeAnswered(response.statusCode, 'Google Drive list failed: HTTP ${response.statusCode}');
    }
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>?) ?? const [];
    if (files.isEmpty) return null;
    final first = files.first as Map<String, dynamic>;
    return first['id'] as String?;
  }

  /// Disconnect the Google account from sync (used when switching provider).
  Future<void> disconnect() async {
    try {
      await _gsi.disconnect();
    } catch (e) {
      AppLogger.debug('Google Drive disconnect failed (ignored): $e');
    }
    _account = null;
  }
}
