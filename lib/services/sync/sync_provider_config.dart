import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/sync/sync_backend.dart';

/// Persisted choice of sync backend plus its connection details.
///
/// The whole object is serialized to a single JSON string in OS-backed
/// secure storage (it holds secrets - WebDAV password, S3 secret key, a
/// custom-server token), never plain SharedPreferences.
class SyncProviderConfig {
  final SyncBackendKind kind;

  /// Optional friendly label shown in the UI.
  final String? label;

  // ── Custom ZestSSH-protocol server ──
  /// Base URL INCLUDING the version segment, e.g. `https://sync.me/v1`.
  final String? serverUrl;

  /// Optional static bearer token (for self-hosted servers not using the
  /// Firebase/session auth).
  final String? serverToken;

  // ── WebDAV ──
  final String? webdavUrl;
  final String? webdavUsername;
  final String? webdavPassword;
  final String? webdavPath;

  // ── S3-compatible ──
  final String? s3Endpoint;
  final String? s3Region;
  final String? s3Bucket;
  final String? s3AccessKeyId;
  final String? s3SecretAccessKey;
  final String? s3Prefix;
  final bool s3UsePathStyle;

  const SyncProviderConfig({
    required this.kind,
    this.label,
    this.serverUrl,
    this.serverToken,
    this.webdavUrl,
    this.webdavUsername,
    this.webdavPassword,
    this.webdavPath,
    this.s3Endpoint,
    this.s3Region,
    this.s3Bucket,
    this.s3AccessKeyId,
    this.s3SecretAccessKey,
    this.s3Prefix,
    this.s3UsePathStyle = true,
  });

  /// The default: the hosted ZestSSH Cloud.
  const SyncProviderConfig.zestServer() : this(kind: SyncBackendKind.zestServer);

  /// Whether every field the chosen backend needs is present. The settings
  /// UI blocks saving until this is true, so downstream construction is safe.
  bool get isComplete {
    switch (kind) {
      case SyncBackendKind.zestServer:
      case SyncBackendKind.googleDrive:
        return true;
      case SyncBackendKind.custom:
        if (!_has(serverUrl)) return false;
        final s = serverUrl!.trim();
        if (!(s.startsWith('http://') || s.startsWith('https://'))) {
          return false;
        }
        // A custom server MUST bring its own static token: the account
        // (Firebase/session) bearer token is never sent off api.zestssh.com,
        // so without a store-scoped token there is nothing to authenticate
        // with. (The backend also refuses to send the account token - this is
        // the clean UI-time gate for the same rule.)
        if (!_has(serverToken)) return false;
        // Don't let "custom" - which turns the Cloud Sync entitlement check
        // OFF - be pointed at the hosted API host to get paid sync for free
        // (server-side enforcement is the real gate, but block it here too).
        final host = Uri.tryParse(s)?.host.toLowerCase() ?? '';
        if (host.isNotEmpty && host == _hostedHost) return false;
        return true;
      case SyncBackendKind.webdav:
        return _has(webdavUrl) &&
            _has(webdavUsername) &&
            _has(webdavPassword) &&
            _pathSafe(webdavPath);
      case SyncBackendKind.s3:
        return _has(s3Endpoint) &&
            _has(s3Region) &&
            _has(s3Bucket) &&
            _has(s3AccessKeyId) &&
            _has(s3SecretAccessKey) &&
            _pathSafe(s3Prefix);
    }
  }

  static bool _has(String? s) => s != null && s.trim().isNotEmpty;

  /// The hosted API host, so a `custom` config can't masquerade as it.
  static String get _hostedHost => (Uri.tryParse(kZestApiBase))?.host.toLowerCase() ?? kZestApiHost;

  /// A store path/prefix is safe only if it has no `.`/`..` segment and no
  /// backslash, `?`, `#`, or control char - otherwise the wire path can escape
  /// the configured folder or diverge from a signed canonical path. Empty is
  /// fine (the backend supplies a default).
  static bool _pathSafe(String? p) {
    final s = (p ?? '').trim();
    if (s.isEmpty) return true;
    if (RegExp(r'[\x00-\x1f\x7f\\?#]').hasMatch(s)) return false;
    for (final seg in s.split('/')) {
      if (seg == '.' || seg == '..') return false;
    }
    return true;
  }

  /// Identifies WHICH physical store this config points at (kind + location),
  /// ignoring credentials. Changing this while sync is active means the data
  /// key/version bookkeeping no longer applies, so the caller must disconnect
  /// locally before pointing at the new store - otherwise a benign-looking
  /// URL/bucket edit strands sync with a stale DEK/version.
  String get storeIdentity {
    switch (kind) {
      case SyncBackendKind.zestServer:
      case SyncBackendKind.googleDrive:
        return kind.name;
      case SyncBackendKind.custom:
        return '${kind.name}|${(serverUrl ?? '').trim()}';
      case SyncBackendKind.webdav:
        return '${kind.name}|${(webdavUrl ?? '').trim()}'
            '|${(webdavPath ?? '').trim()}';
      case SyncBackendKind.s3:
        return '${kind.name}|${(s3Endpoint ?? '').trim()}'
            '|${(s3Bucket ?? '').trim()}|${(s3Prefix ?? '').trim()}';
    }
  }

  /// The address this config would send a reusable credential to (the
  /// WebDAV Basic-auth password, a custom server's token) or the vault itself
  /// (S3, which signs its requests: but over plain http anyone on the way
  /// had the encrypted vault with what a guess at its password needs, and
  /// could hand back an older one, found in a security review of
  /// the client); null where the backend only ever speaks https (the
  /// hosted service, Google Drive).
  String? get _credentialUrl {
    switch (kind) {
      case SyncBackendKind.webdav:
        return webdavUrl;
      case SyncBackendKind.custom:
        return serverUrl;
      case SyncBackendKind.s3:
        return s3Endpoint;
      case SyncBackendKind.zestServer:
      case SyncBackendKind.googleDrive:
        return null;
    }
  }

  /// How this config would use plain http: not at all, to an address on the
  /// person's own network (allowed, with a note), or to anything else
  /// (refused). One rule on every platform: see `own_network_http.dart`.
  PlainHttpUse get plainHttpUse => plainHttpUseOf(_credentialUrl);

  /// A hard-blocking error if the chosen transport would send a reusable
  /// credential in the clear over plain `http://` to a host that is not on
  /// the person's own network. Null when safe (https, no scheme (taken as
  /// https), or an own-network address where plain http is their choice).
  String? get insecureTransportError =>
      plainHttpUse == PlainHttpUse.refused ? gl10n.plainHttpOwnNetworkOnly : null;

  Map<String, dynamic> toJson() => {
        'kind': kind.storageKey,
        if (label != null) 'label': label,
        if (serverUrl != null) 'serverUrl': serverUrl,
        if (serverToken != null) 'serverToken': serverToken,
        if (webdavUrl != null) 'webdavUrl': webdavUrl,
        if (webdavUsername != null) 'webdavUsername': webdavUsername,
        if (webdavPassword != null) 'webdavPassword': webdavPassword,
        if (webdavPath != null) 'webdavPath': webdavPath,
        if (s3Endpoint != null) 's3Endpoint': s3Endpoint,
        if (s3Region != null) 's3Region': s3Region,
        if (s3Bucket != null) 's3Bucket': s3Bucket,
        if (s3AccessKeyId != null) 's3AccessKeyId': s3AccessKeyId,
        if (s3SecretAccessKey != null) 's3SecretAccessKey': s3SecretAccessKey,
        if (s3Prefix != null) 's3Prefix': s3Prefix,
        's3UsePathStyle': s3UsePathStyle,
      };

  factory SyncProviderConfig.fromJson(Map<String, dynamic> json) {
    return SyncProviderConfig(
      kind: SyncBackendKindX.fromStorageKey(json['kind'] as String?),
      label: json['label'] as String?,
      serverUrl: json['serverUrl'] as String?,
      serverToken: json['serverToken'] as String?,
      webdavUrl: json['webdavUrl'] as String?,
      webdavUsername: json['webdavUsername'] as String?,
      webdavPassword: json['webdavPassword'] as String?,
      webdavPath: json['webdavPath'] as String?,
      s3Endpoint: json['s3Endpoint'] as String?,
      s3Region: json['s3Region'] as String?,
      s3Bucket: json['s3Bucket'] as String?,
      s3AccessKeyId: json['s3AccessKeyId'] as String?,
      s3SecretAccessKey: json['s3SecretAccessKey'] as String?,
      s3Prefix: json['s3Prefix'] as String?,
      s3UsePathStyle: json['s3UsePathStyle'] as bool? ?? true,
    );
  }

  SyncProviderConfig copyWith({
    SyncBackendKind? kind,
    String? label,
    String? serverUrl,
    String? serverToken,
    String? webdavUrl,
    String? webdavUsername,
    String? webdavPassword,
    String? webdavPath,
    String? s3Endpoint,
    String? s3Region,
    String? s3Bucket,
    String? s3AccessKeyId,
    String? s3SecretAccessKey,
    String? s3Prefix,
    bool? s3UsePathStyle,
  }) {
    return SyncProviderConfig(
      kind: kind ?? this.kind,
      label: label ?? this.label,
      serverUrl: serverUrl ?? this.serverUrl,
      serverToken: serverToken ?? this.serverToken,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      webdavUsername: webdavUsername ?? this.webdavUsername,
      webdavPassword: webdavPassword ?? this.webdavPassword,
      webdavPath: webdavPath ?? this.webdavPath,
      s3Endpoint: s3Endpoint ?? this.s3Endpoint,
      s3Region: s3Region ?? this.s3Region,
      s3Bucket: s3Bucket ?? this.s3Bucket,
      s3AccessKeyId: s3AccessKeyId ?? this.s3AccessKeyId,
      s3SecretAccessKey: s3SecretAccessKey ?? this.s3SecretAccessKey,
      s3Prefix: s3Prefix ?? this.s3Prefix,
      s3UsePathStyle: s3UsePathStyle ?? this.s3UsePathStyle,
    );
  }
}
