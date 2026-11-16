import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/keychain.dart';

// App version for the X-Client-Version header, so the backend's write-verification
// log-only phase can tell an old/misbehaving client from a stolen-token attack.
// Cached after first lookup.
String? _cachedClientVersion;
Future<String> _clientVersion() async {
  if (_cachedClientVersion != null) return _cachedClientVersion!;
  try {
    final info = await PackageInfo.fromPlatform();
    _cachedClientVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    _cachedClientVersion = 'unknown';
  }
  return _cachedClientVersion!;
}

/// [SyncBackend] that speaks the ZestSSH sync HTTP protocol.
///
/// Two shapes share this one class:
///
/// * **Hosted** - the default `api.zestssh.com` server. Authenticated with
///   the Firebase ID token (mobile) or the browser-OAuth session JWT
///   (desktop), TLS checked by the system's store (no pin), gated on Cloud Sync.
/// * **Custom / self-hosted** - a server the user runs that speaks the same
///   protocol, reached at [baseUrl]. Auth is either the same Firebase/session
///   token (if their server trusts the ZestSSH Firebase project) or a static
///   bearer [staticToken] they configure. Not entitlement-gated.
///
/// The bodies here are the transport half of what used to live in
/// [SyncService]; the crypto half (derive/wrap/encrypt/…) stays static on
/// [SyncService] and is called from here for the shared parts (encrypt on
/// push, unwrap on recovery).
class ZestServerBackend implements SyncBackend {
  /// Base URL including the `/v1` path segment, e.g.
  /// `https://api.zestssh.com/v1` or `https://sync.example.com/v1`.
  final String baseUrl;

  /// Optional static bearer token for self-hosted servers that don't verify
  /// Firebase tokens. When null, the Firebase/session auth path is used.
  final String? staticToken;

  @override
  final bool requiresEntitlement;

  @override
  final SyncBackendKind kind;

  ZestServerBackend({
    required this.baseUrl,
    this.staticToken,
    this.requiresEntitlement = true,
    this.kind = SyncBackendKind.zestServer,
  });

  /// The default hosted backend (api.zestssh.com, entitlement-gated).
  factory ZestServerBackend.hosted() => ZestServerBackend(
        baseUrl: _hostedBaseUrl,
        requiresEntitlement: true,
        kind: SyncBackendKind.zestServer,
      );

  static String get _hostedBaseUrl => kZestApiBase;

  @override
  String get displayName =>
      kind == SyncBackendKind.zestServer ? 'ZestSSH Cloud' : 'Custom server';

  // ── Auth ──────────────────────────────────────────────────────────

  Future<Map<String, String>> _authHeaders({bool forceFresh = true}) async {
    // Self-hosted static-token path: no Firebase involved.
    if (staticToken != null && staticToken!.isNotEmpty) {
      return {
        'Authorization': 'Bearer $staticToken',
        'Content-Type': 'application/json',
      };
    }

    // A custom/self-hosted server must authenticate with ITS OWN static token.
    // Falling through to the Firebase/session token would send the user's
    // ZestSSH ACCOUNT credential (a bearer token that identifies them to
    // api.zestssh.com) to an arbitrary user-supplied URL - an identity-token
    // exfiltration vector. Only the hosted backend may use the account token.
    if (kind != SyncBackendKind.zestServer) {
      throw SyncException(gl10n.syncServerNeedsToken, detail: 'No access token set for this sync server');
    }

    // Mobile: Firebase ID token. Desktop: browser-OAuth session JWT stashed
    // in secure storage. The backend accepts either.
    var token = await AuthService.getIdToken(forceRefresh: forceFresh);
    token ??= await AccountSecret.sessionToken.read(appKeychain);
    if (token == null) throw SyncException(gl10n.syncSignInFirst, detail: 'Not signed in');
    return {
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
      'Content-Type': 'application/json',
      'X-Client-Version': await _clientVersion(),
    };
  }

  /// One-shot retry on a 401/403 with a forced-fresh token. Skipped entirely
  /// for the static-token path (nothing to refresh).
  Future<http.Response> _authedRequest(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    var headers = await _authHeaders();
    // Hard deadline: a dead socket after a long idle otherwise hangs the whole
    // sync cycle forever (stranding _isSyncing). A timeout throws instead, so
    // auto-sync's finally clears the guard and the next cycle can retry.
    var response = await send(headers).timeout(const Duration(seconds: 30));
    if ((response.statusCode == 401 || response.statusCode == 403) &&
        // (Keys that are not the account's are not a token gone stale, and
        // neither is storage that does not come with the account.)
        !keysDoNotMatch(response.statusCode, response.body) &&
        !_hostingRefused(response.statusCode, response.body) &&
        !_deviceLimit(response.statusCode, response.body) &&
        (staticToken == null || staticToken!.isEmpty)) {
      AppLogger.warning(
        'Sync API got ${response.statusCode}, retrying with forced-fresh '
        'token (body=${_truncate(response.body)})',
      );
      try {
        await AuthService.reloadCurrentUser();
      } catch (_) {
        // Best-effort.
      }
      headers = await _authHeaders();
      response = await send(headers).timeout(const Duration(seconds: 30));
      if (response.statusCode == 401 || response.statusCode == 403) {
        AppLogger.warning(
          'Sync API still ${response.statusCode} after refresh '
          '(body=${_truncate(response.body)})',
        );
      }
      // Signed out from another device: the app signs out here.
      reportIfSessionRevoked(response);
    }
    if (_hostingRefused(response.statusCode, response.body)) throw SyncHostingRequiredException(SyncFailure.hostingNotIncluded);
    if (_deviceLimit(response.statusCode, response.body)) throw SyncCloudDeviceLimitException(SyncFailure.cloudDeviceLimit);
    return response;
  }

  /// GET [path] under a hard body cap, streaming-aborting before a rogue/
  /// compromised server can OOM the client (a plain `http.get` buffers the
  /// WHOLE body before any size check). Same 401/403 forced-fresh retry as
  /// [_authedRequest]. `followRedirects:false` keeps the bearer token from
  /// being replayed to a redirect target a hostile server points us at.
  Future<CappedResponse> _authedGetCapped(String path, int maxBytes) async {
    Future<CappedResponse> once(Map<String, String> headers) {
      final req = http.Request('GET', _uri(path))
        ..headers.addAll(headers)
        ..followRedirects = false;
      return sendCapped(_http, req, maxBytes);
    }

    var headers = await _authHeaders();
    var resp = await once(headers);
    bool refused(CappedResponse r) => _hostingRefused(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
    bool limited(CappedResponse r) => _deviceLimit(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
    if ((resp.statusCode == 401 || resp.statusCode == 403) &&
        !refused(resp) &&
        !limited(resp) &&
        (staticToken == null || staticToken!.isEmpty)) {
      try {
        await AuthService.reloadCurrentUser();
      } catch (_) {/* best-effort */}
      headers = await _authHeaders();
      resp = await once(headers);
    }
    if (refused(resp)) throw SyncHostingRequiredException(SyncFailure.hostingNotIncluded);
    if (limited(resp)) throw SyncCloudDeviceLimitException(SyncFailure.cloudDeviceLimit);
    return resp;
  }

  static String _truncate(String s) =>
      s.length > 240 ? '${s.substring(0, 240)}…' : s;

  static String _parseServerError(http.Response response) => _serverWords(response.statusCode, response.body);

  /// What the server said in [body], its answer of [status]: its own
  /// words where it gave some, cleaned and cut short.
  static String _serverWords(int status, String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final err = decoded['error'] as String?;
      if (err == null || err.trim().isEmpty) return 'Unknown error';
      // A custom / self-hosted server is not fully trusted. Strip control
      // characters / newlines and cap the length so a hostile server can't
      // spam, distort, or spoof the notification / sync-status UI with the
      // error text that gets surfaced verbatim.
      final clean = err.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
      return _truncate(clean.isEmpty ? 'Unknown error' : clean);
    } catch (_) {
      return 'Server error (HTTP $status)';
    }
  }

  /// What the server answered [status] to [what] ("Push", "Status check"),
  /// as the person is told it, in their language, with what it said kept
  /// for the details (3.0, 16 October 2026: "Push failed: Internal server
  /// error", in English, and a fault of ZestSSH Cloud's not told for one,
  /// the server's words holding no status). A fault of the server's own
  /// keeps its status in its words, so that [SyncFailure.ofStore] says it
  /// as ZestSSH Cloud's fault, or with the code of storage of one's own.
  SyncException _answered(String what, int status, String body) {
    // (What is not the server's own answer, a page of something on the way,
    // has no words of its own to keep.)
    final detail = _saidByServer(body)
        ? '$what failed: ${_serverWords(status, body)} (HTTP $status)'
        : '$what failed: HTTP $status';
    final cloud = kind.isHosted;
    if (status >= 500 && status <= 599) return SyncFailure.storeAnswered(status, detail);
    return switch (status) {
      // A computer's sign-in that ran out: signing in again where the
      // person is keeps sync (found in a security review).
      401 when cloud && _codeOf(body) == 'session-expired' =>
        SyncException(gl10n.syncCloudSignInRanOut, detail: detail),
      // (ZestSSH Cloud's own refusal of a sign-in is in its words; an
      // answer that is not is something else on the way.)
      401 || 403 when !cloud || _saidByServer(body) =>
        SyncException(cloud ? gl10n.syncCloudSignInRefused : gl10n.syncServerTokenRefused, detail: detail),
      413 => SyncFailure.storeTooLarge(detail),
      429 => SyncException(cloud ? gl10n.syncCloudTooMany : gl10n.syncServerTooMany, detail: detail),
      _ when cloud => SyncException(gl10n.syncCloudAnswerUnknown(status), detail: detail),
      _ => SyncFailure.storeAnswered(status, detail),
    };
  }

  /// The code of the server's own answer in [body], or null.
  static String? _codeOf(String body) {
    try {
      final decoded = jsonDecode(body);
      final code = decoded is Map ? decoded['code'] : null;
      return code is String ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [body] is the server's own answer, with its words.
  static bool _saidByServer(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['error'] is String;
    } catch (_) {
      return false;
    }
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// The client for this server. The hosted service is https only. A custom
  /// server the person runs themselves may be plain http on their own
  /// network, and only there: that is the one rule in `own_network_http.dart`,
  /// applied to every request, which also lifts the phone's blanket refusal
  /// of http for a request the rule lets through. (A getter, not a field:
  /// the pinned client underneath is replaced when its pins are reset.)
  http.Client get _http =>
      debugHttpClient ??
      (kind == SyncBackendKind.custom
          ? OwnNetworkHttpClient(inner: PinnedHttpClient.client, closeInner: false)
          : PinnedHttpClient.client);

  /// Stands in for the network in tests.
  @visibleForTesting
  static http.Client? debugHttpClient;

  /// The most a small answer of the server may be (a status, a verification,
  /// an acknowledgement): they are a few hundred bytes of JSON.
  static const _ackCap = 1024 * 1024;

  /// [_http] for every call but the pull: its answers are read under
  /// [_ackCap]. A plain `get` or `post` reads the whole body before anything
  /// looks at its size, so a server that is not what it should be (or a
  /// person's own, misconfigured) could fill the device's memory with the
  /// answer to a status check. The pull was read under a cap already, with
  /// its own, larger one (found in a security audit, and
  /// still open for these seven calls in a later one).
  http.Client get _small => CappedClient(_http, _ackCap);

  /// Whether the server refused a push ([statusCode], [body]) because this
  /// device's keys are not the account's: its 403 "Sync verification failed"
  /// (a newer server also sends the code SYNC_VERIFICATION_FAILED). It is not
  /// a sign-in problem, and a fresh token or another try changes nothing.
  static bool keysDoNotMatch(int statusCode, String body) {
    if (statusCode != 403) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      return decoded['code'] == 'SYNC_VERIFICATION_FAILED' || decoded['error'] == 'Sync verification failed';
    } catch (_) {
      return false;
    }
  }

  /// Whether ZestSSH Cloud refused because it keeps no copy for this account
  /// ([statusCode], [body]): its storage comes with Juiced, and its 403 with
  /// the code ENTITLEMENT_REQUIRED says the account has none. Not a sign-in
  /// problem: a fresh token or another try changes nothing.
  static bool hostingNotIncluded(int statusCode, String body) {
    if (statusCode != 403) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['code'] == 'ENTITLEMENT_REQUIRED';
    } catch (_) {
      return false;
    }
  }

  /// [hostingNotIncluded], said by ZestSSH Cloud itself: a server of the
  /// person's own that answered so is not said to be ZestSSH Cloud.
  bool _hostingRefused(int statusCode, String body) => kind.isHosted && hostingNotIncluded(statusCode, body);

  /// Whether ZestSSH Cloud refused this device ([statusCode], [body]) because
  /// the account syncs on as many devices as one person may (7):
  /// its 403 with the code cloud-device-limit.
  /// Not a sign-in problem: a fresh token or another try changes nothing
  /// until a device is signed out.
  static bool deviceLimitReached(int statusCode, String body) {
    if (statusCode != 403) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['code'] == 'cloud-device-limit';
    } catch (_) {
      return false;
    }
  }

  /// [deviceLimitReached], said by ZestSSH Cloud itself (a server of the
  /// person's own counts no devices).
  bool _deviceLimit(int statusCode, String body) => kind.isHosted && deviceLimitReached(statusCode, body);

  /// Whether the server refused a push ([statusCode], [body]) because the
  /// account's cloud sync was reset and not set up again yet: its 426 with
  /// the code SYNC_WAS_RESET.
  static bool wasReset(int statusCode, String body) {
    if (statusCode != 426) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['code'] == 'SYNC_WAS_RESET';
    } catch (_) {
      return false;
    }
  }

  // ── SyncBackend ───────────────────────────────────────────────────

  @override
  Future<void> checkConnection() async {
    // getStatus is the lightest authenticated round-trip.
    try {
      await getStatus();
    } on SyncException {
      rethrow;
    } catch (e) {
      // Keep the headline plain ("can't reach…"); park the raw ClientException/
      // SocketException text in `detail` for the copy-details button rather
      // than dumping it into the message.
      final friendly = describeNetworkError(e, subject: gl10n.errSubjectSyncServer);
      throw SyncException(friendly.message, detail: friendly.detail);
    }
  }

  @override
  Future<({int version, int blobSize, DateTime? updatedAt})> push({
    required Map<String, dynamic> data,
    required SecretKey dek,
    required Uint8List salt,
    required Uint8List verificationHash,
    String? deviceId,
    Uint8List? wrappedDekPassword,
    Uint8List? wrappedDekRecovery,
    Uint8List? recoverySalt,
    Uint8List? recoveryHash,
    int? expectedVersion,
    // create-only is now sent as `create_only` so the server can enforce it (a
    // create-push that finds existing data must 409, matching the If-None-Match
    // guard the dumb stores already apply). Until the server honours it, the
    // null expected_version + the pre-push getStatus check are the protection;
    // sending the flag is forward-safe (an old server ignores the extra field).
    bool createOnly = false,
    Map<String, dynamic>? argon2Params,
    Uint8List? authorizeHash,
    Uint8List? authorizeRecoveryHash,
  }) async {
    final encrypted = await SyncService.encrypt(data, dek, salt);

    final payload = <String, dynamic>{
      'encrypted_data': base64Encode(encrypted),
      'salt': base64Encode(salt),
      'password_hash': base64Encode(verificationHash),
      // Proof of the old password on a password rotation, so the server accepts
      // a changed password_hash under write-verification. Omitted otherwise.
      if (authorizeHash != null) 'authorize_hash': base64Encode(authorizeHash),
      // Proof of the recovery key on a recovery-reset - authorizes the changed
      // password_hash when the old password is unknown.
      if (authorizeRecoveryHash != null)
        'authorize_recovery_hash': base64Encode(authorizeRecoveryHash),
      // Send the params the wrapped DEK was derived under - NOT the current
      // code default. Otherwise a data-only sync from a client whose default
      // has since changed would overwrite the stored params and strand any
      // device that re-derives from them.
      'argon2_params': argon2Params ?? SyncService.argon2Params,
      'expected_version': ?expectedVersion,
      // Unambiguous create signal for the server's create-or-409 enforcement.
      if (createOnly) 'create_only': true,
      if (wrappedDekPassword != null)
        'wrapped_dek_password': base64Encode(wrappedDekPassword),
      if (wrappedDekRecovery != null)
        'wrapped_dek_recovery': base64Encode(wrappedDekRecovery),
      if (recoverySalt != null) 'recovery_salt': base64Encode(recoverySalt),
      if (recoveryHash != null) 'recovery_hash': base64Encode(recoveryHash),
    };

    final response = await _authedRequest(
      (headers) => _small.post(
        _uri('/sync/push'),
        headers: headers,
        body: jsonEncode(payload),
      ),
    );

    if (response.statusCode == 409) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw SyncConflictException(
        serverVersion: body['server_version'] as int? ?? -1,
        expectedVersion: body['expected_version'] as int? ?? -1,
      );
    }

    // 426: the server rejected this push. There are no existing sync accounts,
    // so this only fires on a device carrying stale local sync state - surface
    // whatever the server says and stop. SyncSetupRequiredException makes
    // auto-sync PAUSE instead of retry-looping the rejected push.
    if (response.statusCode == 426) {
      // Cloud sync was reset from one of the account's devices: said in the
      // app's language, as the thing it is.
      if (wasReset(response.statusCode, response.body)) {
        throw SyncWasResetException(gl10n.syncWasReset);
      }
      throw SyncSetupRequiredException(gl10n.syncStoreDataMissing,
          detail: 'Push refused: ${_parseServerError(response)} (HTTP 426)');
    }

    // 403 "Sync verification failed": the keys this device sends are not the
    // account's. It was said as a server that could not be reached and sent
    // again on every cycle; it pauses auto-sync and says what to do.
    if (keysDoNotMatch(response.statusCode, response.body)) {
      throw SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
    }

    if (response.statusCode != 200) {
      throw _answered('Push', response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    AppLogger.info('Sync push complete, version: ${body['version']}, '
        'blob: ${encrypted.length} bytes');
    final written = body['updated_at'];
    return (
      version: body['version'] as int,
      blobSize: encrypted.length,
      // (A server from before 3.0 does not say when; the device then learns
      // it the next time it asks how the store stands.)
      updatedAt: written is String ? DateTime.tryParse(written) : null,
    );
  }

  @override
  Future<SyncPullResult> pull() async {
    // The pull body is base64+JSON over the encrypted blob (~1.4× the blob),
    // so cap at 2× maxBlobBytes and stream-abort rather than buffering first.
    final response =
        await _authedGetCapped('/sync/pull', SyncService.maxBlobBytes * 2);

    if (response.statusCode == 404) {
      throw SyncFailure.storeEmpty;
    }

    if (response.statusCode != 200) {
      throw _answered('Pull', response.statusCode, utf8.decode(response.bodyBytes, allowMalformed: true));
    }

    final body = jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, dynamic>;
    return SyncPullResult(
      encryptedData: base64Decode(body['encrypted_data'] as String),
      salt: base64Decode(body['salt'] as String),
      version: body['version'] as int,
      updatedAt: DateTime.parse(body['updated_at'] as String),
      wrappedDekPassword: body['wrapped_dek_password'] != null
          ? base64Decode(body['wrapped_dek_password'] as String)
          : null,
      wrappedDekRecovery: body['wrapped_dek_recovery'] != null
          ? base64Decode(body['wrapped_dek_recovery'] as String)
          : null,
      recoverySalt: body['recovery_salt'] != null
          ? base64Decode(body['recovery_salt'] as String)
          : null,
      // A blob with no params predates the v2 default → treat as legacy 64 MB
      // everywhere downstream, never the current 128 MB default.
      argon2Params: (body['argon2_params'] as Map<String, dynamic>?) ??
          SyncService.legacyArgon2Params,
    );
  }

  @override
  Future<RecoveryPullResult> pullWithRecoveryKey(String recoveryKey) async {
    final pullResult = await pull();

    if (pullResult.recoverySalt == null ||
        pullResult.wrappedDekRecovery == null) {
      throw SyncException(gl10n.syncStoreNoRecoveryKey,
          detail: 'Recovery key has not been configured for this account');
    }

    final normalizedKey = RecoveryKeyService.normalize(recoveryKey);
    final recoveryKek = await SyncService.deriveKey(
      normalizedKey,
      Uint8List.fromList(pullResult.recoverySalt!),
      params: pullResult.argon2Params,
    );

    final recoveryVerificationHash =
        await SyncService.computeRecoveryVerificationHash(recoveryKek);
    final verifyResponse = await _authedRequest(
      (headers) => _small.post(
        _uri('/sync/verify-recovery'),
        headers: headers,
        body: jsonEncode({
          'recovery_hash': base64Encode(recoveryVerificationHash),
        }),
      ),
    );

    if (verifyResponse.statusCode == 200) {
      final verifyBody =
          jsonDecode(verifyResponse.body) as Map<String, dynamic>;
      if (verifyBody['valid'] != true) {
        throw const SyncRecoveryKeyWrongException();
      }
    } else if (verifyResponse.statusCode == 429) {
      // The server takes ten tries in a quarter of an hour.
      throw SyncException(gl10n.twoStepErrorTooMany,
          detail: 'verify-recovery: HTTP 429');
    } else {
      // The server did not answer the question, so nothing is known of the
      // key: a fault of its own, a sign-in it does not take, a way to it
      // that answers in its place.
      throw SyncException(
          ErrorCodes.withCode(gl10n.syncRecoveryKeyNotChecked, ErrorCodes.recoveryKeyNotChecked),
          detail: 'verify-recovery: ${_parseServerError(verifyResponse)}');
    }

    final dek = await SyncService.unwrapDek(
      pullResult.wrappedDekRecovery!,
      recoveryKek,
    );

    return RecoveryPullResult(
      pullResult: pullResult,
      dek: dek,
      recoveryKek: recoveryKek,
    );
  }

  @override
  Future<SyncStatus> getStatus() async {
    final response = await _authedRequest(
      (headers) => _small.get(
        _uri('/sync/status'),
        headers: headers,
      ),
    );

    if (response.statusCode != 200) {
      throw _answered('Status check', response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    // The HTTP Date header is the server's own wall clock - used to warn about a
    // skewed local clock that would corrupt newest-wins conflict resolution.
    DateTime? serverTime;
    final dateHeader = response.headers['date'];
    if (dateHeader != null) {
      try {
        serverTime = HttpDate.parse(dateHeader).toUtc();
      } catch (_) {}
    }
    return SyncStatus(
      hasData: body['has_data'] as bool,
      version: body['version'] as int,
      blobSize: body['blob_size'] as int,
      updatedAt: body['updated_at'] != null
          ? DateTime.parse(body['updated_at'] as String)
          : null,
      lastDevice: body['last_device'] as String?,
      serverTime: serverTime,
      // Older servers do not say; the Account screen then asks nothing of it.
      hasRecovery: body['has_recovery'] is bool ? body['has_recovery'] as bool : null,
    );
  }

  @override
  Future<bool> verifyPassword(SecretKey mek) async {
    final verificationHash = await SyncService.computeVerificationHash(mek);

    final response = await _authedRequest(
      (headers) => _small.post(
        _uri('/sync/verify-password'),
        headers: headers,
        body: jsonEncode({
          'password_hash': base64Encode(verificationHash),
        }),
      ),
    );

    if (response.statusCode != 200) {
      throw _answered('Verification', response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['valid'] as bool;
  }

  @override
  Future<void> verifyEntitlement() async {
    if (!requiresEntitlement) return;

    final response = await _authedRequest(
      (headers) => _small.post(
        _uri('/auth/verify-entitlement'),
        headers: headers,
      ),
    );

    if (response.statusCode != 200) {
      throw _answered('Entitlement verification', response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final hasCloudSync = body['has_cloud_sync'] as bool? ?? false;
    // Asked of the server, which reads the purchases again and remembers
    // what it found: a purchase made a moment ago counts from here on.
    if (!hasCloudSync) throw SyncHostingRequiredException(SyncFailure.hostingNotIncluded);
  }

  @override
  Future<void> purge(Uint8List verificationHash) async {
    final response = await _authedRequest(
      (headers) => _small.post(
        _uri('/sync/purge'),
        headers: headers,
        body: jsonEncode({
          'password_hash': base64Encode(verificationHash),
        }),
      ),
    );

    if (response.statusCode != 200) {
      // The sync password given is not the account's: nothing was deleted.
      if (keysDoNotMatch(response.statusCode, response.body)) {
        throw SyncException(gl10n.accountDeleteWrongSyncPassword,
            detail: 'Purge failed: ${_parseServerError(response)} (HTTP 403)');
      }
      throw _answered('Purge', response.statusCode, response.body);
    }

    AppLogger.info('Sync data purged');
  }

  @override
  Future<void> deleteAccount(Uint8List verificationHash) async {
    final response = await _authedRequest(
      (headers) => _small.post(
        _uri('/account/delete'),
        headers: headers,
        body: jsonEncode({
          'password_hash': base64Encode(verificationHash),
        }),
      ),
    );

    if (response.statusCode != 200) {
      throw _answered('Account delete', response.statusCode, response.body);
    }

    AppLogger.info('Server account deleted');
  }
}
