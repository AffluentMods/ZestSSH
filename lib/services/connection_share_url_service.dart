import 'dart:convert';

import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

/// Whether [text] looks like a host's share link, for offering to read it (a
/// search field, the clipboard, a file): it may still be refused when read.
bool looksLikeShareLink(String text) {
  final t = text.trim().toLowerCase();
  return t.startsWith('zestssh://share') || t.startsWith('zestssh://add-host');
}

/// Parses and emits `zestssh://` URLs that share an SSH connection
/// profile. Two flavors:
///
/// 1. **Plain query params** - `zestssh://add-host?host=foo&port=22&user=ops&label=Prod`
///    Easy for vendors / cloud dashboards to construct by hand.
///    Limited to a single host with no port forwards.
///
/// 2. **Base64 JSON payload** - `zestssh://share?d=<base64-url-encoded-json>`
///    Full structure: host + port + user + label + port forwards +
///    tags + identity hint + group hint. The shape we use when
///    generating QR codes from existing connections.
///
/// ## Hard security rules
///
/// **Never accept secrets in URLs.** The parser actively rejects any
/// URL containing `password=`, `key=`, `private_key=`, `token=`,
/// `secret=` regardless of where they appear. There's no path that
/// will read a password from a URL - the only credential reference
/// allowed is `identityHint`, a *label* the user resolves to a local
/// identity manually.
///
/// **Auto-connect / auto-forward disabled.** Imported connections are
/// added with `autoStart: false` for all forwards. The user has to
/// tap to open a session and tap each forward to start it. A
/// malicious URL can't trigger a network connection on its own.
///
/// **Confirmation always required.** This service only PARSES; the
/// caller (DeepLinkService / QR scanner) is responsible for showing
/// the confirmation dialog before the parsed payload is written to
/// the database.
class ConnectionShareUrlService {
  /// Schema version. Bump if we make a breaking change to the JSON
  /// payload shape - the parser refuses unknown versions so older
  /// builds don't accidentally import a half-understood new format.
  static const int currentSchemaVersion = 1;

  /// Reserved query param names that we reject outright. If a URL
  /// contains ANY of these (whether in the top-level query or
  /// embedded in the base64 JSON), the whole URL is rejected - there
  /// is no legitimate reason a connection-share URL would carry
  /// these fields, and refusing them prevents downstream code from
  /// being tricked into treating a URL as a credential source.
  static const _forbiddenFields = {
    'password',
    'pass',
    'pwd',
    'key',
    'private_key',
    'privatekey',
    'private-key',
    'token',
    'secret',
    'api_key',
    'apikey',
    'apiKey',
    'auth',
    'authorization',
  };

  /// Hard upper bound on the base64 payload size. ~10 KB of base64 →
  /// ~7.5 KB of JSON, which is far more than a sane connection
  /// profile would ever need. Anything larger is either malicious or
  /// a bug in the producer.
  static const int _maxBase64Bytes = 10 * 1024;

  /// The longest a share link can be: its payload at [_maxBase64Bytes] and
  /// the rest of the link around it. A link the device opens, or one pasted,
  /// that is longer is refused before it is read.
  static const int maxLinkChars = 12 * 1024;

  /// Hard upper bound on per-string field length inside the payload.
  /// Defends against memory-pressure tricks where a single field is
  /// 1 MB.
  static const int _maxStringField = 1024;

  /// Maximum port forwards we'll accept on a single shared
  /// connection. Way above any realistic use case; existing in-app
  /// concurrency limit is 50 active forwards.
  static const int _maxForwards = 20;

  /// Try to parse the given URI as a connection-share URL.
  ///
  /// Returns the parsed payload on success, null if the URI is not a
  /// share URL OR if it failed validation. All rejection reasons are
  /// logged via [AppLogger.warning] so we can debug malformed
  /// producers (or detect drive-by attack attempts) from the logs.
  static ParsedConnectionShare? tryParse(Uri uri) {
    if (uri.scheme != 'zestssh') return null;
    final path = uri.host + uri.path;

    if (path == 'add-host') {
      return _parseAddHost(uri);
    }
    if (path == 'share') {
      return _parseShare(uri);
    }
    return null;
  }

  // ── Plain query-param flavor (add-host) ────────────────────────

  static ParsedConnectionShare? _parseAddHost(Uri uri) {
    if (_containsForbidden(uri.queryParameters.keys)) {
      AppLogger.warning(
        'Share URL rejected: forbidden field present in add-host',
      );
      return null;
    }

    final host = _bareHost(_string(uri.queryParameters['host']));
    if (host == null || !_isValidHost(host)) {
      AppLogger.warning('Share URL rejected: missing or invalid host');
      return null;
    }

    final portStr = uri.queryParameters['port'];
    int port = 22;
    if (portStr != null && portStr.isNotEmpty) {
      final p = int.tryParse(portStr);
      if (p == null || p < 1 || p > 65535) {
        AppLogger.warning('Share URL rejected: invalid port');
        return null;
      }
      port = p;
    }

    final user = _string(uri.queryParameters['user']);
    if (user != null && !_isValidUsername(user)) {
      AppLogger.warning('Share URL rejected: invalid user');
      return null;
    }

    final label = _string(uri.queryParameters['label']) ?? host;
    if (!_isValidLabel(label)) {
      AppLogger.warning('Share URL rejected: invalid label');
      return null;
    }

    final identityHint = _string(uri.queryParameters['identity']);
    if (identityHint != null && !_isValidLabel(identityHint)) {
      AppLogger.warning('Share URL rejected: invalid identity hint');
      return null;
    }

    return ParsedConnectionShare(
      label: label,
      host: host,
      port: port,
      user: user,
      identityHint: identityHint,
      forwards: const [],
      tags: const [],
      groupHint: null,
      sourceFormat: ShareSourceFormat.queryParams,
    );
  }

  // ── Base64 JSON flavor (share) ─────────────────────────────────

  static ParsedConnectionShare? _parseShare(Uri uri) {
    if (_containsForbidden(uri.queryParameters.keys)) {
      AppLogger.warning('Share URL rejected: forbidden field in share');
      return null;
    }

    final data = uri.queryParameters['d'];
    if (data == null || data.isEmpty) {
      AppLogger.warning('Share URL rejected: missing d= payload');
      return null;
    }
    if (data.length > _maxBase64Bytes) {
      AppLogger.warning(
        'Share URL rejected: oversize payload (${data.length} bytes)',
      );
      return null;
    }

    final Map<String, dynamic> json;
    try {
      // Use base64Url (URL-safe alphabet) and tolerate missing padding.
      var padded = data;
      final mod = padded.length % 4;
      if (mod != 0) padded = padded + ('=' * (4 - mod));
      final bytes = base64Url.decode(padded);
      final text = utf8.decode(bytes);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        AppLogger.warning('Share URL rejected: payload is not an object');
        return null;
      }
      json = decoded;
    } catch (e) {
      AppLogger.warning('Share URL rejected: payload decode failed: $e');
      return null;
    }

    // Refuse forbidden fields anywhere in the payload, including
    // nested ones.
    if (_jsonContainsForbidden(json)) {
      AppLogger.warning(
        'Share URL rejected: forbidden field present in share payload',
      );
      return null;
    }

    final version = json['v'];
    if (version is! int || version != currentSchemaVersion) {
      AppLogger.warning(
        'Share URL rejected: unsupported schema version $version',
      );
      return null;
    }

    final host = _bareHost(_string(json['host']));
    if (host == null || !_isValidHost(host)) {
      AppLogger.warning('Share URL rejected: missing or invalid host');
      return null;
    }

    final portRaw = json['port'];
    int port = 22;
    if (portRaw is int) {
      if (portRaw < 1 || portRaw > 65535) {
        AppLogger.warning('Share URL rejected: invalid port');
        return null;
      }
      port = portRaw;
    }

    final user = _string(json['user']);
    if (user != null && !_isValidUsername(user)) {
      AppLogger.warning('Share URL rejected: invalid user');
      return null;
    }

    final label = _string(json['label']) ?? host;
    if (!_isValidLabel(label)) {
      AppLogger.warning('Share URL rejected: invalid label');
      return null;
    }

    final identityHint = _string(json['identityHint']);
    if (identityHint != null && !_isValidLabel(identityHint)) {
      AppLogger.warning('Share URL rejected: invalid identity hint');
      return null;
    }

    final groupHint = _string(json['groupHint']);
    if (groupHint != null && !_isValidLabel(groupHint)) {
      AppLogger.warning('Share URL rejected: invalid group hint');
      return null;
    }

    // Tags ─────────────────────────────────────────────────────────
    final tagsRaw = json['tags'];
    final tags = <String>[];
    if (tagsRaw is List) {
      for (final t in tagsRaw) {
        final s = _string(t);
        if (s == null) continue;
        if (!_isValidLabel(s)) {
          AppLogger.warning('Share URL rejected: invalid tag');
          return null;
        }
        tags.add(s);
        if (tags.length > 32) {
          AppLogger.warning('Share URL rejected: too many tags');
          return null;
        }
      }
    }

    // Forwards ─────────────────────────────────────────────────────
    final forwardsRaw = json['forwards'];
    final forwards = <SharedForward>[];
    if (forwardsRaw is List) {
      if (forwardsRaw.length > _maxForwards) {
        AppLogger.warning(
          'Share URL rejected: too many forwards (${forwardsRaw.length})',
        );
        return null;
      }
      for (final f in forwardsRaw) {
        if (f is! Map<String, dynamic>) {
          AppLogger.warning('Share URL rejected: forward is not an object');
          return null;
        }
        final parsed = _parseForward(f);
        if (parsed == null) return null;
        forwards.add(parsed);
      }
    }

    return ParsedConnectionShare(
      label: label,
      host: host,
      port: port,
      user: user,
      identityHint: identityHint,
      forwards: forwards,
      tags: tags,
      groupHint: groupHint,
      sourceFormat: ShareSourceFormat.base64Json,
    );
  }

  static SharedForward? _parseForward(Map<String, dynamic> f) {
    if (_jsonContainsForbidden(f)) {
      AppLogger.warning('Share URL rejected: forbidden field in forward');
      return null;
    }
    final type = _string(f['type']);
    if (type != 'local' && type != 'remote' && type != 'dynamic') {
      AppLogger.warning('Share URL rejected: unknown forward type $type');
      return null;
    }
    final bindPort = f['bindPort'];
    if (bindPort is! int || bindPort < 1 || bindPort > 65535) {
      AppLogger.warning('Share URL rejected: invalid forward bindPort');
      return null;
    }
    final bindAddress = _string(f['bindAddress']) ?? '127.0.0.1';
    if (!_isValidHost(bindAddress)) {
      AppLogger.warning('Share URL rejected: invalid forward bindAddress');
      return null;
    }

    String remoteHost = '';
    int remotePort = 0;
    if (type != 'dynamic') {
      final rh = _string(f['remoteHost']);
      if (rh == null || !_isValidHost(rh)) {
        AppLogger.warning('Share URL rejected: invalid forward remoteHost');
        return null;
      }
      remoteHost = rh;
      final rp = f['remotePort'];
      if (rp is! int || rp < 1 || rp > 65535) {
        AppLogger.warning('Share URL rejected: invalid forward remotePort');
        return null;
      }
      remotePort = rp;
    }

    final label = _string(f['label']);
    if (label != null && !_isValidLabel(label)) {
      AppLogger.warning('Share URL rejected: invalid forward label');
      return null;
    }

    return SharedForward(
      type: type!,
      bindAddress: bindAddress,
      bindPort: bindPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
    );
  }

  // ── Outbound: build a share URL from an existing connection ────

  /// Construct the `zestssh://share?d=...` URL for a connection.
  ///
  /// Names (the label, the key and group hints, tags, forward labels) are
  /// carried as [shareableName] makes them, so a name the person may give
  /// a host ("Mom's NAS") never stops the link from being made.
  ///
  /// Throws an [ArgumentError] if any of the input fields would
  /// fail this service's own parser - that way we never emit a URL
  /// that another device would reject.
  static Uri buildShareUrl({
    required String label,
    required String host,
    required int port,
    String? user,
    String? identityHint,
    String? groupHint,
    List<String> tags = const [],
    List<SharedForward> forwards = const [],
  }) {
    final shownLabel = shareableName(label) ?? host;
    final keyHint = shareableName(identityHint);
    final group = shareableName(groupHint);
    final tagNames = [for (final t in tags) ?shareableName(t)];
    final payload = <String, dynamic>{
      'v': currentSchemaVersion,
      'label': shownLabel,
      'host': host,
      'port': port,
      if (user != null && user.isNotEmpty) 'user': user,
      'identityHint': ?keyHint,
      'groupHint': ?group,
      if (tagNames.isNotEmpty) 'tags': tagNames,
      if (forwards.isNotEmpty)
        'forwards': forwards
            .map((f) => {
                  'type': f.type,
                  'bindAddress': f.bindAddress,
                  'bindPort': f.bindPort,
                  if (f.type != 'dynamic') 'remoteHost': f.remoteHost,
                  if (f.type != 'dynamic') 'remotePort': f.remotePort,
                  'label': ?shareableName(f.label),
                })
            .toList(),
    };

    final json = jsonEncode(payload);
    final encoded = base64Url
        .encode(utf8.encode(json))
        // Strip padding for shorter URLs; the parser pads on the way back.
        .replaceAll('=', '');
    final uri = Uri.parse('zestssh://share').replace(
      queryParameters: {'d': encoded},
    );

    // Round-trip sanity check - refuse to ship a URL we can't read
    // back. Catches edge cases like fields that pass our outbound
    // checks but fail the parser's stricter regex rules.
    final reparsed = tryParse(uri);
    if (reparsed == null) {
      throw ArgumentError('Constructed share URL failed parser validation');
    }
    return uri;
  }

  /// The look-alike a share link carries for each character the parser
  /// refuses in a name: an apostrophe as a typographic one, and so on.
  static const _nameLookAlikes = {
    0x27: 0x2019, // ' as ’
    0x22: 0x201D, // " as ”
    0x60: 0x2018, // ` as ‘
    0x5C: 0xFF3C, // \ as ＼
    0x3C: 0x2039, // < as ‹
    0x3E: 0x203A, // > as ›
  };

  /// [name] as a share link carries it, so the parser takes it: each
  /// character it refuses in a name as its look-alike, control and spoofing
  /// characters left out, cut at 128 characters. Null for no name.
  static String? shareableName(String? name) {
    if (name == null) return null;
    final out = StringBuffer();
    for (final r in name.runes) {
      if (r < 0x20 || r == 0x7F || isSpoofingControl(r)) continue;
      final c = String.fromCharCode(_nameLookAlikes[r] ?? r);
      if (out.length + c.length > 128) break;
      out.write(c);
    }
    final s = out.toString().trim();
    return s.isEmpty ? null : s;
  }

  // ── Internal helpers ───────────────────────────────────────────

  static bool _containsForbidden(Iterable<String> keys) {
    for (final k in keys) {
      if (_forbiddenFields.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  static bool _jsonContainsForbidden(Map<String, dynamic> json) {
    if (_containsForbidden(json.keys)) return true;
    for (final v in json.values) {
      if (v is Map<String, dynamic>) {
        if (_jsonContainsForbidden(v)) return true;
      } else if (v is List) {
        for (final item in v) {
          if (item is Map<String, dynamic> && _jsonContainsForbidden(item)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  static String? _string(dynamic v) {
    if (v == null) return null;
    if (v is! String) return null;
    if (v.isEmpty) return null;
    if (v.length > _maxStringField) return null;
    // Reject C0 control characters anywhere.
    if (RegExp(r'[\x00-\x1f]').hasMatch(v)) return null;
    // Reject Unicode bidi-override and zero-width characters - in an
    // attacker-supplied share link they can spoof how a label/host/tag
    // reads (e.g. a right-to-left override makes a hostile value display
    // as a benign one).
    if (hasSpoofingControl(v)) return null;
    return v;
  }

  /// Hostnames + IP literals - letters, digits, dots, hyphens,
  /// colons (IPv6), brackets. No spaces, no control chars, no
  /// URL-injection-ish punctuation.
  /// [s] without the brackets an IPv6 address may come in: what a host
  /// is saved as and connected to (saved with them, it could not be).
  static String? _bareHost(String? s) => s == null ? null : unbracketHost(s);

  static bool _isValidHost(String s) {
    if (s.isEmpty || s.length > 253) return false;
    return RegExp(r'^[A-Za-z0-9._:\-\[\]]+$').hasMatch(s);
  }

  static bool _isValidUsername(String s) {
    if (s.isEmpty || s.length > 64) return false;
    // POSIX-ish: alphanumeric + . _ - @ (some IdPs use email-style)
    return RegExp(r'^[A-Za-z0-9._@\-]+$').hasMatch(s);
  }

  static bool _isValidLabel(String s) {
    if (s.isEmpty || s.length > 128) return false;
    // Labels are user-facing - allow Unicode word chars + common
    // punctuation. Reject anything that could be HTML / shell.
    if (RegExp(r'''[<>"'`\\]''').hasMatch(s)) return false;
    // Reject bidi-override / zero-width spoofing characters.
    if (hasSpoofingControl(s)) return false;
    return true;
  }

  /// Unicode bidi-override (RLO/LRO/RLE/LRE/PDF/isolates), directional
  /// marks, zero-width chars, word joiner, and BOM/ZWNBSP - all of which
  /// can make an attacker-supplied string display differently than it is.
  /// A shared host's file is held to it too (ConnectionShareService).
  static bool hasSpoofingControl(String s) => s.runes.any(isSpoofingControl);

  /// Whether the character [r] is one [hasSpoofingControl] refuses.
  static bool isSpoofingControl(int r) =>
      // NB: allow U+200C (ZWNJ) and U+200D (ZWJ) - those are required in
      // legitimate emoji sequences (👨‍💻, flags) and in Persian/Arabic/Indic
      // scripts, so they belong in real labels. Only the actual spoofing
      // controls below are rejected.
      r == 0x200B ||                  // zero-width space
      (r >= 0x200E && r <= 0x200F) || // LRM / RLM
      (r >= 0x202A && r <= 0x202E) || // bidi embeddings/overrides
      (r >= 0x2060 && r <= 0x2064) || // word joiner + invisible ops
      (r >= 0x2066 && r <= 0x2069) || // bidi isolates
      r == 0xFEFF;                    // BOM / ZWNBSP
}

/// Source of a parsed share URL - useful for UI to explain to the
/// user how the data arrived (a long base64 blob vs. a vendor's
/// hand-crafted query-param URL).
enum ShareSourceFormat { queryParams, base64Json }

/// Validated connection-share payload. Built ONLY by
/// [ConnectionShareUrlService.tryParse] - never construct this
/// directly from untrusted input, the rules baked into the parser
/// are the security boundary.
class ParsedConnectionShare {
  final String label;
  final String host;
  final int port;
  final String? user;
  final String? identityHint;
  final List<SharedForward> forwards;
  final List<String> tags;
  final String? groupHint;
  final ShareSourceFormat sourceFormat;

  const ParsedConnectionShare({
    required this.label,
    required this.host,
    required this.port,
    required this.user,
    required this.identityHint,
    required this.forwards,
    required this.tags,
    required this.groupHint,
    required this.sourceFormat,
  });
}

class SharedForward {
  final String type; // 'local' | 'remote' | 'dynamic'
  final String bindAddress;
  final int bindPort;
  final String remoteHost;
  final int remotePort;
  final String? label;

  const SharedForward({
    required this.type,
    required this.bindAddress,
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
    required this.label,
  });
}
