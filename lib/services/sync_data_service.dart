import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/models/host_icon_limits.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/database/daos/connection_groups_dao.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/identities_dao.dart';
import 'package:zestssh/database/daos/known_hosts_dao.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/daos/networks_dao.dart';
import 'package:zestssh/database/daos/port_forward_rules_dao.dart';
import 'package:zestssh/database/daos/snippet_categories_dao.dart';
import 'package:zestssh/database/daos/snippets_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/features/sftp/remote_path_sanitizer.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/secret_seal.dart';

// ── Safe cast helpers ────────────────────────────────────────────
// JSON decode can return int where we expect String and vice versa.
// These helpers handle both without crashing.

String _str(dynamic v) => v?.toString() ?? '';
String? _strOpt(dynamic v) => v?.toString();

/// The id of another record that a restored record points at (a host's key,
/// its group, its jump host), or none: an empty one, or one longer than any
/// id the app makes (the same 128 a record's own id is held to), points at
/// nothing. They were taken as sent, at any length (found in security
/// audits).
String? _idOpt(dynamic v) {
  final id = v?.toString();
  return id == null || id.isEmpty || id.length > 128 ? null : id;
}
int _int(dynamic v) => v is int ? v : int.tryParse(v.toString()) ?? 0;
int? _intOpt(dynamic v) =>
    v == null ? null : (v is int ? v : int.tryParse(v.toString()));
bool _bool(dynamic v) =>
    v is bool ? v : (v.toString().toLowerCase() == 'true');
DateTime _dateTime(dynamic v) {
  // tryParse (not parse) so one malformed date in an untrusted blob can't
  // throw inside the restore transaction and abort the whole restore.
  if (v is! String) return DateTime.now();
  return DateTime.tryParse(v) ?? DateTime.now();
}
DateTime? _dateTimeOpt(dynamic v) =>
    v == null ? null : (v is String ? DateTime.tryParse(v) : null);

/// Parse a DateTime from a sync-blob value regardless of encoding. Drift's
/// `toJson` serializes a DateTime column as a unix timestamp (int SECONDS by
/// default), whereas our own tombstone `deletedAt` is written as an ISO string.
/// Tombstone "newest wins" compares a record's `updatedAt` against a tombstone,
/// so both encodings must decode to the same instant. Returns UTC.
DateTime? _flexDateTime(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is int) {
    // Guard against a millisecond value too (magnitude heuristic: a seconds
    // timestamp for any realistic date is < 1e11).
    return v > 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
  }
  return null;
}

// ── Restore-time validation helpers ─────────────────────────────
// Untrusted data from backup files or sync blobs is validated before
// being written to the local database to prevent injection attacks.

/// Reject strings with ANY C0 control or DEL. Applied to host/IP/bind-address
/// fields, where TAB/CR/LF must be rejected too - a hostname carrying a line
/// break can smuggle a second command/header into anything that later renders
/// or shells out with the value (log/terminal-title/ProxyCommand injection).
bool _hasControlChars(String s) =>
    RegExp(r'[\x00-\x1f\x7f]').hasMatch(s);

/// Chars stripped from every rendered free-text field pulled from an untrusted
/// blob: C0 controls (except TAB/LF/CR so multi-line notes/commands survive),
/// DEL + C1, and the Unicode bidi/format controls used for homoglyph/RTL
/// spoofing of labels and hostnames on host cards. Mirrors the bidi check
/// `ConnectionShareUrlService.hasSpoofingControl` uses on the share-URL path.
final RegExp _renderUnsafe = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f'
    r'\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// Valid identity `authMethod` values (matches the `AuthMethod` enum names in
/// identity_edit_screen.dart). An unrecognised value from a blob falls back to
/// 'password' rather than being written verbatim, so a crafted method string
/// can't drive the auth UI/engine down an unexpected path.
const _validAuthMethods = {
  'password',
  'publicKey',
  'certificate',
  'hardwareToken',
  // 3.0: its password stays in the person's password manager.
  'passwordManager',
};

/// Whose agent holds an agent-backed identity's key.
const _validAgentSources = {'1password', 'bitwarden', 'system'};

String? _validateAgentSource(dynamic v) => _validAgentSources.contains(v) ? v as String : null;

/// A password manager reference, only when it reads as one: a bad
/// value from the blob is dropped, never passed to a password manager.
String? _validatePasswordRef(dynamic v) => v is String ? PasswordRef.decode(v)?.encode() : null;

String _validateAuthMethod(dynamic v) {
  final s = v?.toString() ?? '';
  return _validAuthMethods.contains(s) ? s : 'password';
}

/// Validate a hostname/IP: max 253 chars, no control characters.
String? _validateHost(dynamic v) {
  final s = v?.toString() ?? '';
  if (s.isEmpty || s.length > 253 || _hasControlChars(s)) return null;
  return s;
}

/// Validate a port number: 1-65535.
int? _validatePort(dynamic v) {
  final p = _int(v);
  if (p < 1 || p > 65535) return null;
  return p;
}

/// Validate a protocol value.
String _validateProtocol(dynamic v) {
  final s = v?.toString() ?? 'ssh';
  // Every protocol the app can store. A synced Serial or Local Shell host
  // used to be coerced to ssh here and come out the other side as an SSH
  // connection to a nonsense address; unknown values still fall back. (A
  // version from before SFTP-only hosts falls back to ssh for 'sftp', and
  // sends the host on as SSH the next time it syncs.)
  // A remote screen (4.0, 'vnc') too: a version from before it never reads
  // one, since screens go in a list of their own ([SyncDataService.gatherAll]).
  // An RDP host (4.0, 'rdp') the same, in its own list.
  const valid = {
    'ssh', 'sftp', 'mosh', 'et', 'telnet', 'serial', 'localShell', 'demo', 'ftps', 'ftpsImplicit', 'vnc', 'rdp', //
  };
  return valid.contains(s) ? s : 'ssh';
}

/// Validate a synced home-card size code (0=Medium row, 1=Large full card,
/// 2=legacy Large, 3=Small square; 3.0 no longer shows it, apps before 3.0 do).
/// Absent or out-of-range values fall back to the standard full card (code 1)
/// so an older blob (pre-v18) or untrusted data can never carry a nonsense
/// code. Valid codes are 0-3; code 3 must be preserved or a synced Small host
/// would silently upsize to the full card on an app before 3.0.
int _validateTier(dynamic v) {
  // Use the NULLABLE parse: _int() collapses a non-numeric value to 0, but 0 is
  // now a valid code (Medium/row), so a malformed blob would silently render as
  // a half-row instead of the documented full-card fallback. _intOpt() returns
  // null on parse failure, so every invalid value correctly falls back to 1.
  final n = _intOpt(v);
  if (n == null || n < 0 || n > 3) return 1;
  return n;
}

/// Bound a rendered free-text field from an untrusted blob: strip NUL bytes
/// and TRUNCATE to [maxLen] rather than dropping the whole field, so a long
/// value degrades gracefully instead of vanishing across a sync round-trip.
/// Caps render/layout cost (a multi-MB label/note is a UI-isolate DoS) and
/// rejects embedded NULs. Applied uniformly to every free-text field so no
/// one field is left unprotected while a sibling is hardened.
String _capText(String s, int maxLen) {
  // Strip NUL/control + bidi-spoofing chars, THEN truncate. Uniform across
  // every free-text field so no rendered field is left unsanitised while a
  // sibling is hardened.
  final stripped = s.replaceAll(_renderUnsafe, '');
  if (stripped.length <= maxLen) return stripped;
  // Cut on a whole character: the limit counts UTF-16 units, and a cut
  // between the two halves of one (an emoji across the limit) left the text
  // ending in half a character, which reads as a replacement sign and
  // changes once more when it is next written as UTF-8 (found in security
  // audits). The share
  // file's reader cuts the same way.
  final last = maxLen > 0 ? stripped.codeUnitAt(maxLen - 1) : 0;
  final half = last >= 0xD800 && last <= 0xDBFF;
  return stripped.substring(0, half ? maxLen - 1 : maxLen);
}

/// Line-break / tab chars stripped from pin fields. `_capText`'s `_renderUnsafe`
/// deliberately KEEPS `\t\r\n` (so multi-line notes/commands survive), but a pin
/// label/path is single-line + path-like, so a synced peer must not be able to
/// smuggle a newline into a rail label (cosmetic spoofing) - mirror how host /
/// path fields reject line breaks elsewhere.
final RegExp _pinLineBreaks = RegExp(r'[\t\r\n]');

/// Sanitise the SFTP `pins` JSON from an untrusted sync blob (schema v30) - a
/// JSON array of `{"label":…,"path":…}`. Re-serialised from a bounded, cleaned
/// subset (≤100 pins, label/path capped + control-stripped incl. line breaks)
/// so a lying peer can't bloat the row or smuggle spoofing chars into the rail.
/// Anything malformed collapses to null, never throws.
String? _pinsJson(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  if (v.length > 65536) return null; // hard cap before parsing
  try {
    final decoded = jsonDecode(v);
    if (decoded is! List) return null;
    final out = <Map<String, String>>[];
    for (final e in decoded) {
      if (out.length >= 100) break;
      if (e is! Map) continue;
      final path =
          _capText(_str(e['path']), 4096).replaceAll(_pinLineBreaks, '');
      if (path.isEmpty) continue;
      final label =
          _capText(_str(e['label']), 128).replaceAll(_pinLineBreaks, '');
      out.add({'label': label.isEmpty ? path : label, 'path': path});
    }
    return out.isEmpty ? null : jsonEncode(out);
  } catch (_) {
    return null;
  }
}

/// Clamp a restored integer into [min]..[max]; unparseable/absent → [fallback]
/// (then clamped). Untrusted blobs otherwise put out-of-range ints straight
/// into the DB, e.g. a huge keepAliveSeconds overflows into a negative
/// Duration that busy-loops the keepalive timer, or a negative colorIndex
/// crashes the desktop pill bar's palette lookup.
int _clampInt(dynamic v, int min, int max, {int fallback = 0}) {
  var n = _intOpt(v) ?? fallback;
  if (n < min) n = min;
  if (n > max) n = max;
  return n;
}

/// Nullable variant - returns null for absent input, otherwise capped.
/// A host's cloud-import link from a blob: kept only when it reads as one
/// (see `CloudLink.decode`), so a damaged or oversized value restores as
/// "not linked" rather than as something the importer would trust.
String? _cloudSourceOpt(dynamic v) => v is String && CloudLink.decode(v) != null ? v : null;

/// A host's remote screen options from a blob (4.0): kept only on a host
/// restored as a remote screen ([protocol] is the validated one), and only as
/// a JSON object within their bound (`ScreenOptions.sanitize`); anything else
/// restores as none, and the screen opens with the defaults.
String? _screenOptionsOpt(dynamic v, String protocol) =>
    ConnectionProtocol.storedIsScreen(protocol) ? ScreenOptions.sanitize(v) : null;

String? _capTextOpt(dynamic v, int maxLen) {
  final s = _strOpt(v);
  return s == null ? null : _capText(s, maxLen);
}

/// Sanitise envVars JSON: must be a valid JSON object with only
/// shell-safe keys and no control characters in values.
String _sanitizeEnvVars(String raw) {
  if (raw.isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return '';
    final parsed = Map<String, dynamic>.from(decoded);
    final clean = <String, String>{};
    var totalLen = 0;
    for (final entry in parsed.entries) {
      // Cap the ENTRY COUNT - a blob with tens of thousands of vars is a
      // per-connect env-build DoS regardless of individual value size.
      if (clean.length >= 64) break;
      // Key must be a valid shell variable name
      if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(entry.key)) continue;
      final val = entry.value?.toString() ?? '';
      // Reject ANY C0 control (not just NUL): CR/LF etc. can inject extra
      // lines into an env file / `export` sequence.
      if (RegExp(r'[\x00-\x1f]').hasMatch(val)) continue;
      // Cap value length to prevent abuse
      if (val.length > 4096) continue;
      // Cap the TOTAL encoded size so many mid-size values can't add up to a
      // multi-MB env block.
      totalLen += entry.key.length + val.length;
      if (totalLen > 16 * 1024) break;
      clean[entry.key] = val;
    }
    if (clean.isEmpty) return '';
    return jsonEncode(clean);
  } catch (_) {
    return ''; // Malformed JSON - discard
  }
}

/// How long deleted-record tombstones are kept before the retention GC prunes
/// them. Generous on purpose (this is a config vault, not an event stream, so
/// tombstones are cheap) so a device that syncs only occasionally doesn't cross
/// it. A device offline LONGER than this can no longer trust the tombstone set
/// to suppress its resurrections, so the sync cycle routes it through the
/// stale-device reconcile instead of a blind union.
const Duration kTombstoneRetention = Duration(days: 730); // 2 years

/// Whether [address], a forward's bind address, is this device's own
/// (loopback): what a forward from sync may listen on before it is
/// approved on this device.
bool isLoopbackBind(String address) => const {'', '127.0.0.1', '::1', 'localhost'}.contains(address);

/// Handles serializing/deserializing all app data for cloud sync.
///
/// Gathers data from all DAOs + secure storage into a single JSON-compatible
/// map, and restores data from a synced map back into the local database.
class SyncDataService {
  final AppDatabase _database;

  /// Your Tree's database (the one sync and backups read and write).
  AppDatabase get database => _database;

  /// Your Tree's identity secrets, opened and sealed as they are kept
  /// (SecretSeal): they were read and written in the storage as kept.
  late final _identitySecrets = SecureStorageIdentitySecrets(_secureStorage, sealedBy: _database);
  final ConnectionsDao _connectionsDao;
  final IdentitiesDao _identitiesDao;
  final ConnectionGroupsDao _groupsDao;
  final KnownHostsDao _knownHostsDao;
  final SnippetsDao _snippetsDao;
  final SnippetCategoriesDao _snippetCategoriesDao;
  final PortForwardRulesDao _portForwardRulesDao;
  final NetworksDao _networksDao;
  final ConnectionTagsDao _connectionTagsDao;
  final FlutterSecureStorage _secureStorage;
  final SettingsService _settingsService;

  /// The account signed in (its id), whose team keys alone go into the
  /// payload and are taken from it (AccountKeyStore.exportForSync); null
  /// when signed out.
  final String? Function() _accountUid;
  static String? _signedOut() => null;

  SyncDataService({
    required AppDatabase database,
    required ConnectionsDao connectionsDao,
    required IdentitiesDao identitiesDao,
    required ConnectionGroupsDao groupsDao,
    required KnownHostsDao knownHostsDao,
    required SnippetsDao snippetsDao,
    required SnippetCategoriesDao snippetCategoriesDao,
    required PortForwardRulesDao portForwardRulesDao,
    required NetworksDao networksDao,
    required ConnectionTagsDao connectionTagsDao,
    required FlutterSecureStorage secureStorage,
    required SettingsService settingsService,
    String? Function()? accountUid,
  })  : _accountUid = accountUid ?? _signedOut,
        _database = database,
        _connectionsDao = connectionsDao,
        _identitiesDao = identitiesDao,
        _groupsDao = groupsDao,
        _knownHostsDao = knownHostsDao,
        _snippetsDao = snippetsDao,
        _snippetCategoriesDao = snippetCategoriesDao,
        _portForwardRulesDao = portForwardRulesDao,
        _networksDao = networksDao,
        _connectionTagsDao = connectionTagsDao,
        _secureStorage = secureStorage,
        _settingsService = settingsService;

  /// Keyed fingerprint of the SYNCED content, ignoring the volatile
  /// `synced_at` timestamp. Lets the sync engine detect "nothing
  /// meaningful changed" and skip a no-op / echo push. It is HMAC-keyed by
  /// the DEK ([keyBytes]) so the value - which is persisted to plain
  /// SharedPreferences and covers secret material (SSH passwords / private
  /// keys) - can't be recomputed by anyone without the DEK, i.e. it can't
  /// serve as an offline confirmation oracle for those secrets. The DEK
  /// itself never leaves secure storage.
  static String contentFingerprint(
      Map<String, dynamic> data, List<int> keyBytes) {
    const keys = [
      'connections',
      // FTPS hosts (3.4), beside the others ([gatherAll]).
      ftpsHostsKey,
      // Remote screens (4.0), in a list of their own too; only while there
      // is one, so a person with none keeps the fingerprint 3.4 gave them
      // and the update pushes nothing by itself.
      screenHostsKey,
      // RDP hosts (4.0) the same.
      rdpHostsKey,
      'identities',
      'connection_groups',
      'snippets',
      // Snippet-category metadata (order/color/hidden). Has no volatile
      // timestamps, so a category-only change (e.g. reorder or hide) is
      // reflected in the fingerprint and its push isn't echo-skipped.
      'snippet_categories',
      'port_forward_rules',
      // Trigger / highlight rules (v15). Volatile created/updatedAt are stripped
      // by _scrubVolatile, so a rule-only change shows in the fingerprint (its
      // push isn't echo-skipped) while a restore round-trip stays stable.
      'terminal_triggers',
      // Command history (v16): a new command changes the fingerprint so its
      // push isn't echo-skipped; created/updatedAt are volatile-stripped.
      'command_history',
      'secrets',
      // Account keys (v18): a newly confirmed set changes the fingerprint so
      // its push is not echo-skipped; the secret form has no volatile fields.
      'account_keys',
      // Networks feature tables (v1.6) - included so a network-only change
      // is reflected in the fingerprint and its own push isn't echo-skipped.
      // Their volatile createdAt/updatedAt are already stripped by
      // _scrubVolatile, so the pull→restore→gather round-trip stays stable.
      'networks',
      'host_network_overrides',
      'port_forward_network_overrides',
      // Delete-propagation markers (v10). `deletedAt` is meaningful (not
      // volatile), so a new/removed tombstone changes the fingerprint (triggers
      // a push) while a pull→restore→gather round-trip stays stable.
      'tombstones',
      // App/terminal settings allowlist (v12). Has no volatile timestamps and
      // is emitted in a stable key order, so a settings-only change is
      // reflected in the fingerprint (triggers a push) while its own restore
      // round-trip stays byte-stable (no echo push).
      'settings',
      // Connection tags (v13). A `{connectionId: [sortedTags]}` map with no
      // volatile fields, so a tag-only change is reflected in the fingerprint
      // (triggers a push) while its restore round-trip stays byte-stable.
      'connection_tags',
      // A host's other accounts (v22), `{connectionId: [identityIds in order]}`:
      // the same, for a change of accounts only.
      'host_accounts',
    ];
    final stable = {
      for (final k in keys)
        if ((k != screenHostsKey && k != rdpHostsKey) || (data[k] is List && (data[k] as List).isNotEmpty))
          k: _scrubVolatile(data[k]),
    };
    final mac = crypto.Hmac(crypto.sha256, keyBytes);
    return mac.convert(utf8.encode(jsonEncode(stable))).toString();
  }

  /// Fields that change WITHOUT a meaningful user edit - touched on connect,
  /// or rewritten to `now()` by [restoreAll]. They are stripped before
  /// hashing so a pull→restore→gather round-trip yields an IDENTICAL
  /// fingerprint. Without this, the echo-skip guard never matches after a
  /// pull, so every pull triggers a push and two devices ping-pong pushes
  /// forever - the loop that starved the UI isolate and froze the window on
  /// maximize.
  static const _volatileFields = {
    'updatedAt',
    'createdAt',
    'lastConnected',
    'lastSeen',
    'firstSeen',
    'synced_at',
    'syncedAt',
  };

  static Object? _scrubVolatile(Object? v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (!_volatileFields.contains(e.key))
            e.key: _scrubVolatile(e.value),
      };
    }
    if (v is List) return v.map(_scrubVolatile).toList();
    return v;
  }

  /// Each item of [data] (a sync blob, pulled, or gathered here) under its
  /// own name (`connections/<id>` and the like), with the row it is written
  /// as and what goes with it: a host's tags and other accounts, a key's
  /// secrets. An override is named by its pair (a host and a network, a
  /// forward and a network), which is the same on every device where its id
  /// need not be.
  static Iterable<({String name, Map row, Object? extra})> _itemsOf(Map<String, dynamic> data) sync* {
    Map byId(String key) => data[key] is Map ? data[key] as Map : const {};
    final tags = byId('connection_tags');
    final accounts = byId('host_accounts');
    final secrets = byId('secrets');
    Iterable<Map> rows(String kind) sync* {
      final list = data[kind];
      if (list is! List) return;
      for (final e in list) {
        if (e is Map) yield e;
      }
    }

    for (final row in [
      ...rows('connections'),
      ...rows(ftpsHostsKey),
      ...rows(screenHostsKey),
      ...rows(rdpHostsKey),
    ]) {
      final id = _str(row['id']);
      if (id.isNotEmpty) yield (name: 'connections/$id', row: row, extra: {'tags': tags[id], 'accounts': accounts[id]});
    }
    for (final row in rows('identities')) {
      final id = _str(row['id']);
      if (id.isNotEmpty) yield (name: 'identities/$id', row: row, extra: secrets[id]);
    }
    for (final kind in const [
      'connection_groups',
      'snippets',
      'port_forward_rules',
      'terminal_triggers',
      'command_history',
      'networks',
    ]) {
      for (final row in rows(kind)) {
        final id = _str(row['id']);
        if (id.isNotEmpty) yield (name: '$kind/$id', row: row, extra: null);
      }
    }
    for (final row in rows('snippet_categories')) {
      final name = _str(row['name']);
      if (name.isNotEmpty) yield (name: 'snippet_categories/$name', row: row, extra: null);
    }
    for (final row in rows('host_network_overrides')) {
      yield (
        name: 'host_network_overrides/${_str(row['connectionId'])}|${_str(row['networkId'])}',
        row: row,
        extra: null,
      );
    }
    for (final row in rows('port_forward_network_overrides')) {
      yield (
        name: 'port_forward_network_overrides/${_str(row['ruleId'])}|${_str(row['networkId'])}',
        row: row,
        extra: null,
      );
    }
  }

  /// Each item of [data] under its name ([_itemsOf]; a setting as
  /// `settings/<key>`), with a keyed hash of what it holds (3.0): what a pull
  /// compares to tell which side changed an item since the last sync
  /// ([restoreAll] with a [SyncMergeBase]). What changes with no edit of it
  /// is left out, as for [contentFingerprint], and so is an override's own
  /// id. Keyed by the DEK ([keyBytes]) for the reason the fingerprint is: a
  /// key's hash covers its password.
  static Map<String, String> itemHashes(Map<String, dynamic> data, List<int> keyBytes) {
    final mac = crypto.Hmac(crypto.sha256, keyBytes);
    String hash(Object? content) =>
        mac.convert(utf8.encode(jsonEncode(_inOrder(_scrubVolatile(content))))).toString().substring(0, 32);
    final out = <String, String>{};
    for (final item in _itemsOf(data)) {
      final row = item.name.startsWith('host_network_overrides/') || item.name.startsWith('port_forward_network_overrides/')
          ? ({...item.row}..remove('id'))
          : item.row;
      out[item.name] = hash({'row': row, 'with': item.extra});
    }
    final settings = data['settings'];
    if (settings is Map) {
      for (final e in settings.entries) {
        out['settings/${e.key}'] = hash(e.value);
      }
    }
    return out;
  }

  /// [v] with every map's keys in order: the same content is the same text
  /// wherever it was written.
  static Object? _inOrder(Object? v) {
    if (v is Map) {
      final keys = [for (final k in v.keys) '$k']..sort();
      return {for (final k in keys) k: _inOrder(v[k])};
    }
    if (v is List) return v.map(_inOrder).toList();
    return v;
  }

  /// How many rows have been written to the database since it was opened
  /// (inserted, changed or deleted, by a statement or by a trigger): the
  /// same number twice means nothing was written between. The app has one
  /// connection to a database, so every writer is counted.
  Future<int> _writesSoFar() async =>
      (await _database.customSelect('SELECT total_changes() AS n').getSingle()).read<int>('n');

  /// When each item of [data] was last changed, as its row says.
  static Map<String, DateTime?> _changeTimes(Map<String, dynamic> data) => {
        for (final item in _itemsOf(data)) item.name: _flexDateTime(item.row['updatedAt']),
      };

  /// The kinds of item whose time of change every restore kept as the blob
  /// said it: a time this device has for one of them can be trusted before
  /// it has a base to merge with. (The others were stamped as changed by
  /// every pull.)
  static const _timesKept = {'connections', 'snippets'};

  static const _baseKey = 'sync.base';
  static const _baseAsideKey = 'sync.base.aside';

  /// Each item as this device last synced it ([itemHashes] of what it last
  /// pushed, or pulled and took whole), or null where it has kept none yet
  /// (its first sync since 3.0, or sync set up anew). Kept in this device's
  /// encrypted database; never synced, never in a backup.
  Future<Map<String, String>?> loadSyncBase() async {
    try {
      final raw = await LocalStateStore(_database).read(_baseKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
    } catch (e) {
      AppLogger.warning('Sync: what this device last synced could not be read ($e)');
      return null;
    }
  }

  /// Keeps [base] as what this device last synced.
  Future<void> saveSyncBase(Map<String, String> base) =>
      LocalStateStore(_database).write(_baseKey, jsonEncode(base));

  /// Forgets what this device last synced (sync taken apart, or set up anew),
  /// and the highest count it saw of that store.
  Future<void> clearSyncBase() async {
    final store = LocalStateStore(_database);
    await store.remove(_baseKey);
    await store.remove(_storeCountKey);
  }

  /// What this device last synced and the highest count it saw, set aside with
  /// its keys for the account it was signed out of without asking (KeptSync);
  /// [clearSyncBase] does not reach them.
  Future<void> setSyncBaseAside() async {
    final store = LocalStateStore(_database);
    final base = await store.read(_baseKey);
    if (base != null) await store.write(_baseAsideKey, base);
    final count = await store.read(_storeCountKey);
    if (count != null) await store.write(_storeCountAsideKey, count);
  }

  /// Puts what [setSyncBaseAside] kept back in use.
  Future<void> takeSyncBaseBack() async {
    final store = LocalStateStore(_database);
    final base = await store.read(_baseAsideKey);
    if (base != null) await store.write(_baseKey, base);
    await store.remove(_baseAsideKey);
    final count = await store.read(_storeCountAsideKey);
    if (count != null) await store.write(_storeCountKey, count);
    await store.remove(_storeCountAsideKey);
  }

  /// Forgets what [setSyncBaseAside] kept.
  Future<void> dropSyncBaseAside() async {
    final store = LocalStateStore(_database);
    await store.remove(_baseAsideKey);
    await store.remove(_storeCountAsideKey);
  }

  // ── The store's count ───────────────────────────────────────────
  //
  // Nothing about a blob on the outside can be trusted: whoever can write to
  // the store can keep an old blob and give it any version number and time,
  // and a device then takes it for another device's work (the cryptography
  // audit: every item unchanged here since the last sync
  // went back to the old copy, an old address, an old password, with nothing
  // said). So the blob counts for itself, inside its encryption: each push
  // writes one more than the highest this device has seen, and a device that
  // is given a blob below that highest knows it for an old one.
  //
  // A version from before the count ignores the field, and its pushes drop
  // it. A device that has seen no count yet takes a blob without one as
  // ever. One that has seen a count merges a blob without one as a store
  // that went back, and says nothing: it may be an older version's push, or
  // an old copy the store kept from before the count, and the two cannot be
  // told apart. Taken as ever, such a copy put every item unchanged here
  // back to how it was then, on every account that had synced before the
  // count existed (found in a security audit). Merged as a store that
  // went back, what is newer in it is still taken (an older version's later
  // edit), what is newer here stays and is sent back, and this device's
  // settings stay. The next push of a version that counts goes on from the
  // highest it saw. The payload's version stays as it is: nothing is lost by
  // a build that does not know the field.

  /// The count inside a sync blob, and when it was written by its writer's
  /// clock (UTC milliseconds; the blob's `synced_at` has no time zone).
  static const storeCountField = 'store_count';
  static const storeCountAtField = 'store_count_at';

  static const _storeCountKey = 'sync.store_count';
  static const _storeCountAsideKey = 'sync.store_count.aside';

  /// A blob below the highest count this device saw, written no more than
  /// this before it saw that count, may be a push that lost a race on a store
  /// that takes the last write (WebDAV, Google Drive), or one that writes
  /// without looking (a changed password): it is merged as one that went back,
  /// and nothing is said. An old blob a store keeps is older than this.
  static const storeCountRace = Duration(hours: 1);

  /// The count in [data]; null for a blob from before there was one.
  static int? storeCountOf(Map<String, dynamic> data) {
    final count = data[storeCountField];
    // (A count too large to go on from is no count.)
    return count is int && count > 0 && count < (1 << 53) ? count : null;
  }

  /// [data] without the count, as a backup holds it: a backup is no state of
  /// the store, and restoring one says nothing about it.
  static Map<String, dynamic> withoutStoreCount(Map<String, dynamic> data) =>
      {...data}..remove(storeCountField)..remove(storeCountAtField);

  /// The highest count this device saw of the account's store, and when it saw
  /// it; 0 and null where it saw none.
  Future<({int count, DateTime? at})> storeCountSeen() async {
    final raw = await LocalStateStore(_database).read(_storeCountKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return (
          count: json['count'] as int,
          at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int, isUtc: true),
        );
      } catch (e) {
        AppLogger.warning('Sync: the highest count seen could not be read (${errorKind(e)})');
      }
    }
    return (count: 0, at: null);
  }

  /// This device saw [count]: kept where it is the highest yet, never lowered.
  Future<void> noteStoreCount(int count) async {
    if (count <= (await storeCountSeen()).count) return;
    await LocalStateStore(_database).write(
        _storeCountKey, jsonEncode({'count': count, 'at': DateTime.now().toUtc().millisecondsSinceEpoch}));
  }

  /// How the blob [data] stands to what this device saw: [older] where it is
  /// below the highest count seen, so that it is merged as a store that went
  /// back, and [wentBack] where its count says that plainly: it was written
  /// longer before this device saw that count than a race explains. Equal
  /// counts are two devices that pushed at once. A blob with no count is
  /// [older] once this device has seen a count, and never [wentBack]: an
  /// older version of the app pushes such blobs, and nobody is alarmed by
  /// that.
  Future<({bool older, bool wentBack, int? count, int seen})> compareStoreCount(Map<String, dynamic> data) async {
    final count = storeCountOf(data);
    final seen = await storeCountSeen();
    if (count == null) return (older: seen.count > 0, wentBack: false, count: null, seen: seen.count);
    if (count >= seen.count) return (older: false, wentBack: false, count: count, seen: seen.count);
    final written = data[storeCountAtField];
    final at = seen.at;
    final raced = written is int &&
        at != null &&
        !DateTime.fromMillisecondsSinceEpoch(written, isUtc: true).isBefore(at.subtract(storeCountRace));
    return (older: true, wentBack: !raced, count: count, seen: seen.count);
  }

  /// [data], read from the store and about to go back to it as it is (a
  /// changed password, a recovery), with a count of its own and the time now:
  /// what it held was written long ago, and it would pass for an old blob.
  Future<Map<String, dynamic>> stampForPush(Map<String, dynamic> data) async => {
        ...data,
        ...await _nextStoreCount(storeCountOf(data) ?? 0),
      };

  /// The count a push writes: one more than the highest seen here, and than
  /// [read], what it read.
  Future<Map<String, Object>> _nextStoreCount([int read = 0]) async {
    final seen = (await storeCountSeen()).count;
    return {
      storeCountField: (seen > read ? seen : read) + 1,
      storeCountAtField: DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  /// Gather all local data into a JSON-compatible map for sync push.
  Future<Map<String, dynamic>> gatherAll() async {
    // Fetch all data in parallel
    final results = await Future.wait([
      _connectionsDao.getAll(),
      _identitiesDao.getAll(),
      _groupsDao.getAll(),
      _knownHostsDao.getAll(),
      _snippetsDao.getAll(),
      _portForwardRulesDao.getAll(),
      _networksDao.getAll(),
      _networksDao.getAllOverrides(),
      _portForwardRulesDao.getAllNetworkOverrides(),
      _snippetCategoriesDao.getAll(),
      _connectionTagsDao.getAllAssignments(),
    ]);

    final connections = results[0] as List<Connection>;
    final identities = results[1] as List<Identity>;
    final groups = results[2] as List<ConnectionGroup>;
    final knownHosts = results[3] as List<KnownHost>;
    final snippets = results[4] as List<Snippet>;
    final portForwardRules = results[5] as List<PortForwardRule>;
    final networks = results[6] as List<NetworkRow>;
    final hostNetworkOverrides = results[7] as List<HostNetworkOverrideRow>;
    final portForwardNetworkOverrides =
        results[8] as List<PortForwardNetworkOverrideRow>;
    final snippetCategories = results[9] as List<SnippetCategory>;
    final tagAssignments = results[10] as Map<String, List<String>>;

    // Gather secrets for identities: all a key holds goes with it, its saved
    // passphrase and its certificate too (3.0; before, another device and a
    // restored backup got the key without them).
    final secrets = <String, Map<String, String?>>{};
    for (final identity in identities) {
      final password = await _identitySecrets.read(identity.id, IdentitySecret.password);
      final privateKey = await _identitySecrets.read(identity.id, IdentitySecret.privateKey);
      final passphrase = await _identitySecrets.read(identity.id, IdentitySecret.passphrase);
      final certificate = await _identitySecrets.read(identity.id, IdentitySecret.certificate);
      // A secret that is kept here but does not open reads as none. Sent on
      // like that, the key looked as if its secret had been taken off it, and
      // every other device deleted its own readable copy. Nothing is gathered
      // then: the sync or backup that asked fails, and no device loses a
      // secret to this one's seal.
      final read = {
        IdentitySecret.password: password,
        IdentitySecret.privateKey: privateKey,
        IdentitySecret.passphrase: passphrase,
        IdentitySecret.certificate: certificate,
      };
      for (final entry in read.entries) {
        if (entry.value == null && await _identitySecrets.keptButUnread(identity.id, entry.key)) {
          throw KeySecretUnread(SecureStorageIdentitySecrets.keyFor(entry.key, identity.id), label: identity.label);
        }
      }
      if (password != null || privateKey != null || passphrase != null || certificate != null) {
        secrets[identity.id] = {
          // ignore: use_null_aware_elements
          if (password != null) 'password': password,
          // ignore: use_null_aware_elements
          if (privateKey != null) 'privateKey': privateKey,
          // ignore: use_null_aware_elements
          if (passphrase != null) 'passphrase': passphrase,
          // ignore: use_null_aware_elements
          if (certificate != null) 'certificate': certificate,
        };
      }
    }

    // Retention GC: drop tombstones older than the retention window so the sync
    // blob doesn't grow unbounded. This is a config vault, not an event stream -
    // a thousand deletes is a few KB - so the window is generous (2 years) to
    // make the over-window case genuinely rare (a quarterly-use backup laptop
    // shouldn't hit it). A device offline LONGER than this would resurrect the
    // items whose tombstones were pruned, which is why the sync cycle guards it
    // with a stale-device reconcile (see [kTombstoneRetention] usage in
    // auto_sync_service): it stops and asks before re-inserting.
    //
    // Not while this device's clock is known to be wrong ([clockInDoubt]):
    // with a clock far ahead every tombstone looked older than the window and
    // the whole set went at the next gather; with one far behind, "now less
    // two years" is no time to judge by either (found in a security audit).
    if (!clockInDoubt) {
      await _database.tombstonesDao.pruneOlderThan(DateTime.now().subtract(kTombstoneRetention));
    }
    final tombstoneRows = await _database.tombstonesDao.getAll();

    // Trigger / highlight rules (blob v15). Fetched via the db getter so the
    // constructor field list stays untouched.
    final terminalTriggers = await _database.terminalTriggersDao.getAll();
    // Command history (blob v16), same inline-getter approach.
    final commandHistory = await _database.commandHistoryDao.getAll();

    return {
      // v13: connection TAGS now travel (`connection_tags`) so a host's tags
      // follow the user across devices. Fail-closed like every prior bump: a
      // client supporting <= 12 refuses a 13 blob rather than stripping tags
      // and pushing the truncated data back (which would wipe tags fleet-wide).
      // v12: a curated allowlist of app/terminal settings (`settings`) now
      // travels so a device's look-and-feel + connection defaults follow the
      // user. Fail-closed: an older client that supports <= 11 refuses a 12
      // blob rather than round-tripping it and dropping the settings.
      // v11: known_hosts are now RESTORED (host-key trust travels), with
      // per-record provenance and a conflicting-key-is-a-changed-key policy.
      // v14: the SFTP host default (`lastRemotePath` / `lastRemoteUser` /
      // `lastRemotePathAt`, remember-last-folder spec) rides on connections.
      // v15: trigger / highlight rules (`terminal_triggers`) travel so a user's
      // output-watch rules follow them across devices. Fail-closed like every
      // prior bump: a client supporting <= 14 refuses a 15 blob rather than
      // stripping the key and pushing truncated data back.
      // v16: command history (`command_history`) travels so recent commands
      // follow the user across devices (a Squeezed feature; the sync transport
      // stays free). Fail-closed like every prior bump.
      // v18: the account's keys (3.0) travel as `account_keys`,
      // `{accountId: secret}`, confirmed ones only, so every device of an
      // account holds them, protected by the DEK like SSH private keys.
      // Fail-closed like every prior bump.
      // v22 (3.0, accounts per host): a host's other accounts travel as
      // `host_accounts`, and an identity's `passwordAfterKey` (whether the
      // password saved with a key is tried after it). Fail-closed like every
      // prior bump: a build that supports <= 21 refuses a 22 blob rather than
      // pushing every host back without its other accounts.
      'schema_version': 22,
      'synced_at': DateTime.now().toIso8601String(),
      // Counts each push, inside the encryption ([storeCountField]). Not a
      // payload version: a build that does not know it loses nothing by it.
      ...await _nextStoreCount(),
      // FTPS hosts (3.4) go in a list of their own, which a version from
      // before FTPS does not read: it never sees one, so it never takes one
      // for an SSH host (it read an unknown protocol as SSH). A push from such
      // a version leaves the list out, which deletes nothing (only tombstones
      // do); the next push of a version that has FTPS puts it back. A
      // restore puts the two lists together again ([withFtpsHostsJoined]).
      // Remote screens (4.0) the same, in `screen_hosts`: a version from
      // before them never sees one ([withScreenHostsJoined]). RDP hosts in
      // `rdp_hosts` ([withRdpHostsJoined]), apart from the VNC ones, so that a
      // version with VNC and no RDP never takes one for a VNC host.
      'connections': [
        for (final c in connections)
          if (ConnectionProtocol.kindClassOf(c.protocol) == ConnectionProtocol.kindClassShell) hostJson(c),
      ],
      'ftps_hosts': [
        for (final c in connections)
          if (ConnectionProtocol.storedIsFtps(c.protocol)) hostJson(c),
      ],
      screenHostsKey: [
        for (final c in connections)
          if (ConnectionProtocol.kindClassOf(c.protocol) == ConnectionProtocol.kindClassScreen) hostJson(c),
      ],
      rdpHostsKey: [
        for (final c in connections)
          if (ConnectionProtocol.kindClassOf(c.protocol) == ConnectionProtocol.kindClassRdp) hostJson(c),
      ],
      // `allowUnattended` is a DEVICE-LOCAL security flag: authorising a
      // credential for headless runs is a per-device trust decision, so it must
      // never travel in the sync blob. `toJson()` would include it (it's a
      // column), so strip it here - the deserialize side never reads it either,
      // making the property honest end-to-end.
      'identities': identities.map((i) {
        final json = i.toJson();
        // Strip DEVICE-LOCAL / device-specific identity fields. The serialize
        // field set MUST match the restore field set below, or the two devices
        // compute different `contentFingerprint`s for the "same" identity and
        // ping-pong pushes forever (the loop `_scrubVolatile` guards against):
        //  - allowUnattended  : a per-device headless-run trust decision (v25).
        //  - agentSocketPath   : a machine-specific ssh-agent socket / pipe path,
        //                        invalid on another device → set up locally.
        //  - cert* mirrors     : cached metadata parsed from the cert BLOB (which
        //                        is not synced) → regenerated locally.
        // `usesAgent` is deliberately KEPT (it's a real identity property and IS
        // restored below), so an agent-backed identity stays agent-backed on
        // every device instead of degrading to a plain key/password identity.
        for (final k in const [
          'allowUnattended',
          'agentSocketPath',
          'certSerial',
          'certKeyId',
          'certPrincipals',
          'certCaFingerprint',
          'certValidBefore',
          'certValidAfter',
        ]) {
          json.remove(k);
        }
        return json;
      }).toList(),
      'connection_groups': groups.map((g) => g.toJson()).toList(),
      // Host-key trust travels as of blob v11. `recordedDevice` (provenance) IS
      // synced; `locallyVerified` is DEVICE-LOCAL (whether THIS device has
      // confirmed the key) and MUST be stripped, or the restore field set won't
      // match and the two devices ping-pong pushes over the fingerprint diff.
      'known_hosts': knownHosts.map((h) {
        final json = h.toJson();
        json.remove('locallyVerified');
        return json;
      }).toList(),
      // Snippets carry the v23 `metadata` field (blob schema_version 8) -
      // toJson() includes it automatically.
      'snippets': snippets.map((s) => s.toJson()).toList(),
      // Snippet-category metadata (blob schema_version 7).
      'snippet_categories':
          snippetCategories.map((c) => c.toJson()).toList(),
      // What each device decides for itself about a forward does not travel
      // (3.0; a forward's "start automatically" setting kept
      // turning itself off): whether it starts by itself when its host
      // connects, whether other devices on the network may use it, and an
      // address that is not this device's own (loopback). Every restore set
      // those to their safe values, also for a forward the device already
      // had, and the next push carried that to the others, so each sync
      // switched "Start automatically" off again everywhere. As an Orchard's
      // record leaves auto-start on each device.
      'port_forward_rules': portForwardRules.map((r) {
        final json = r.toJson()
          ..remove('autoStart')
          ..remove('gatewayPorts');
        if (!isLoopbackBind(r.bindAddress)) json['bindAddress'] = '127.0.0.1';
        return json;
      }).toList(),
      // Trigger / highlight rules (blob schema_version 15). toJson() carries the
      // pattern, actions, colour, scope and updatedAt for newest-wins.
      'terminal_triggers': terminalTriggers.map((t) => t.toJson()).toList(),
      // Command history (blob schema_version 16). Capped locally so this stays
      // small; toJson carries command/host/timestamps + updatedAt. The v39
      // record-extension columns (exitCode/durationMs/cwd) are LOCAL-ONLY and
      // stripped here so the blob shape and schema_version stay exactly 16 - old
      // devices never see a newer blob and never refuse to sync.
      'command_history': commandHistory.map((h) {
        final j = h.toJson();
        j
          ..remove('exitCode')
          ..remove('durationMs')
          ..remove('cwd');
        return j;
      }).toList(),
      // Networks feature (schema v15 tables + the schema-v19 per-(rule,network)
      // port-forward overrides). Added to the sync/backup payload in blob
      // schema_version 6.
      'networks': networks.map((n) => n.toJson()).toList(),
      'host_network_overrides':
          hostNetworkOverrides.map((o) => o.toJson()).toList(),
      'port_forward_network_overrides':
          portForwardNetworkOverrides.map((o) => o.toJson()).toList(),
      // Delete-propagation tombstones (blob schema_version 10).
      'tombstones': tombstoneRows
          .map((t) => {
                'entityType': t.entityType,
                'entityId': t.entityId,
                'deletedAt': t.deletedAt.toIso8601String(),
              })
          .toList(),
      'secrets': secrets,
      // App/terminal settings allowlist (blob schema_version 12). A plain
      // JSON object of preference keys; SettingsService owns the allowlist and
      // its type/order stability, so a pull -> restore -> gather round-trip is
      // byte-stable and never triggers an echo push.
      'settings': _settingsService.exportSyncedSettings(),
      // Connection tags (blob schema_version 13): `{connectionId: [sortedTags]}`
      // for every connection that has tags. Deterministic (sorted, no volatile
      // fields), so it's byte-stable across a pull -> restore -> gather round
      // trip. Tags ride the connection: restore only applies them to
      // connections that survive tombstones, and deleting a host clears its
      // tags via the existing delete path.
      'connection_tags': tagAssignments,
      // A host's other accounts (blob v22): `{connectionId: [identityIds]}`,
      // in their order, for every host that has any; the default account is
      // the host's own `identityId`. Deterministic, like the tags.
      'host_accounts': await _database.hostAccountsDao.getAllAssignments(),
      'account_keys':
          await AccountKeyStore(_secureStorage, tree: () => _database).exportForSync(account: _accountUid()),
    };
  }

  /// Restore synced data to the local database.
  ///
  /// Uses an upsert strategy: existing records are updated, new ones inserted.
  /// Does NOT delete local records that aren't in the sync blob (merge, not replace).
  /// Highest `schema_version` this build knows how to restore. Bump in lockstep
  /// with the `gatherAll` writer version.
  ///
  /// v6 added the Networks payload (`networks`, `host_network_overrides`,
  /// `port_forward_network_overrides`). The bump is deliberate: a pre-v6 build
  /// doesn't know those keys, so it would strip them on restore and push a
  /// truncated blob back - wiping every device's network profiles/overrides.
  /// The `blobSchema > supportedSchemaVersion` guard below makes such a build
  /// refuse a v6 blob instead, protecting the new data. A v6 build still reads
  /// old (<=5) blobs fine - the new keys are simply absent.
  ///
  /// v7 added `snippet_categories` (per-category order/color/hidden). Same
  /// rationale: a pre-v7 build would strip the key on restore and push a
  /// truncated blob back, wiping category metadata on every device, so the
  /// guard makes it refuse a v7 blob. A v7 build still reads old (<=6) blobs
  /// fine - the key is simply absent (categories fall back to defaults).
  ///
  /// v8 added the snippet `metadata` field (1.7 snippet detail pane: a snippet
  /// description + per-variable descriptions, DB schema v23). Same rationale
  /// once more: a pre-v8 build doesn't restore the field, so it would strip it
  /// and push a truncated blob back - wiping those descriptions on every
  /// device. The guard makes such a build refuse a v8 blob instead. A v8 build
  /// still reads old (<=7) blobs fine - the per-snippet key is simply absent.
  ///
  /// v9 added the custom-colour `colorValue` (a nullable ARGB int) on every
  /// coloured entity - connections, identities, connection_groups,
  /// snippet_categories, networks - plus identity `colorIndex` (which never
  /// synced before). Same rationale once more: a pre-v9 build doesn't restore
  /// those fields, so it would strip them and push a truncated blob back -
  /// wiping every device's custom colours. The guard makes such a build refuse
  /// a v9 blob instead. A v9 build still reads old (<=8) blobs fine - the colour
  /// keys are simply absent (colours fall back to the palette index / default).
  ///
  /// v10 added the `tombstones` list (delete-propagation): "(entityType,
  /// entityId, deletedAt)" markers so a delete on one device removes the record
  /// on the others instead of the union-merge re-adding it. Same fail-closed
  /// rationale - a pre-v10 build doesn't apply tombstones and would strip them
  /// on restore then push a blob that resurrects everything, so the guard makes
  /// it refuse a v10 blob. A v10 build still reads old (<=9) blobs fine (no
  /// `tombstones` key → nothing to apply).
  ///
  /// v19 (3.0) added identity `agentSource` and `passwordRef`
  /// (password managers). Same fail-closed rationale: a pre-v19 build would
  /// strip them on restore and push a truncated blob back, turning every
  /// password-manager identity into an empty password one on every device.
  ///
  /// v20 (3.0, cloud import) added the connection `cloudSource` (where a host
  /// was imported from). Same fail-closed rationale: a pre-v20 build would
  /// strip it and push the hosts back unlinked, so the next check of that
  /// cloud account would add every one of them a second time.
  ///
  /// v21 (3.0) added the connection `iconColor` (what colours a host's icon:
  /// its own colour, the host's label's, or a custom one). Same fail-closed
  /// rationale: a pre-v21 build would strip it and push every host back with
  /// its icon in its own colour, undoing the choice on every device.
  ///
  /// v22 (3.0) added a host's other accounts (`host_accounts`) and an
  /// identity's `passwordAfterKey`. Same fail-closed rationale: a pre-v22
  /// build would push every host back without them.
  static const supportedSchemaVersion = 22;

  /// A host as the blob carries it: its row's JSON, without the columns it
  /// carries only when they hold a value (a remote screen's options, 4.0, set
  /// on a VNC host alone), so every other host, and the blob's fingerprint,
  /// stay what a version before the column wrote. A team host's shared SFTP
  /// bookmarks (4.0) are never in it: they belong to a team's record, and a
  /// personal host has none (your own pins travel as `pins`).
  static Map<String, dynamic> hostJson(Connection c) {
    final json = c.toJson();
    if (json['screenOptions'] == null) json.remove('screenOptions');
    json.remove('sharedPins');
    return json;
  }

  /// The list FTPS hosts (3.4) go in, beside `connections` ([gatherAll]): a
  /// field older versions ignore, rather than a new schema version (which
  /// would stop every older device's sync until it updated).
  static const ftpsHostsKey = 'ftps_hosts';

  /// [data] with its FTPS hosts in `connections` with the others, where a
  /// restore looks for hosts. One that came in `connections` (none should)
  /// stays there; a host in both lists is taken once, from `connections`.
  static Map<String, dynamic> withFtpsHostsJoined(Map<String, dynamic> data) =>
      _joined(data, ftpsHostsKey, ConnectionProtocol.storedIsFtps);

  /// The list remote screens (4.0) go in, beside `connections` and
  /// [ftpsHostsKey] ([gatherAll]): one more field older versions ignore. 3.4
  /// never reads it, and a push of its leaves it out, which deletes no screen
  /// (only a tombstone does); the next push of a version that has screens
  /// puts it back.
  static const screenHostsKey = 'screen_hosts';

  /// [data] with its remote screens in `connections` with the others, as
  /// [withFtpsHostsJoined]: only rows that are VNC screens are taken from the
  /// list.
  static Map<String, dynamic> withScreenHostsJoined(Map<String, dynamic> data) => _joined(
      data, screenHostsKey, (p) => ConnectionProtocol.kindClassOf(p) == ConnectionProtocol.kindClassScreen);

  /// The list RDP hosts (4.0) go in, beside [screenHostsKey]: a
  /// version that has VNC and not RDP reads `screen_hosts` and never this, so
  /// it never sees an RDP host (it would have read one as SSH, a host whose
  /// key's password it then offers to an SSH server that is not there). A
  /// push of such a version leaves the list out, which deletes no RDP host
  /// (only a tombstone does); the next push of a version that has RDP puts it
  /// back.
  static const rdpHostsKey = 'rdp_hosts';

  /// [data] with its RDP hosts in `connections` with the others: only rows
  /// that are RDP hosts are taken from the list.
  static Map<String, dynamic> withRdpHostsJoined(Map<String, dynamic> data) =>
      _joined(data, rdpHostsKey, (p) => ConnectionProtocol.kindClassOf(p) == ConnectionProtocol.kindClassRdp);

  /// Every list of hosts put together in `connections` ([withFtpsHostsJoined],
  /// [withScreenHostsJoined], [withRdpHostsJoined]), where a restore looks for
  /// hosts.
  static Map<String, dynamic> withHostListsJoined(Map<String, dynamic> data) =>
      withRdpHostsJoined(withScreenHostsJoined(withFtpsHostsJoined(data)));

  static Map<String, dynamic> _joined(Map<String, dynamic> data, String key, bool Function(String?) isOfList) {
    final listed = data[key];
    if (listed is! List || listed.isEmpty) return data;
    final hosts = data['connections'] is List ? data['connections'] as List : const [];
    final ids = {for (final c in hosts) if (c is Map) c['id']};
    return {
      ...data,
      'connections': [
        ...hosts,
        for (final c in listed)
          if (c is Map && !ids.contains(c['id']) && isOfList(c['protocol']?.toString())) c,
      ],
    }..remove(key);
  }

  /// Bound a restored custom host-card icon (a base64 PNG) so an untrusted
  /// blob cannot inject a huge payload. Dropped (null) when absent or over the
  /// cap; the uploader downscales real icons to well under this.
  static String? _capCustomIcon(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    if (v.length > kMaxHostIconChars) return null;
    return v;
  }

  // ── Tombstones (delete-propagation, "newest wins") ──────────────
  // Synced entity types the merge can apply a tombstone to. Ids are UUIDs
  // except snippet_categories, whose PK is `name` (handled below).
  static const _tombstoneEntityTypes = {
    'connections',
    'connection_groups',
    'identities',
    'snippets',
    'snippet_categories',
    'networks',
    'port_forward_rules',
    'terminal_triggers',
    'command_history',
    'host_network_overrides',
    'port_forward_network_overrides',
  };

  /// Parse the blob's `tombstones` list into `{entityType: {entityId:
  /// deletedAt}}`, keeping the NEWEST deletedAt per id and dropping malformed /
  /// unknown-type entries.
  static Map<String, Map<String, DateTime>> _parseTombstones(dynamic raw) {
    final out = <String, Map<String, DateTime>>{};
    if (raw is! List) return out;
    for (final t in raw) {
      if (t is! Map) continue;
      final type = _str(t['entityType']);
      final id = _str(t['entityId']);
      final at = _flexDateTime(t['deletedAt']);
      if (at == null) continue;
      if (type.isEmpty || type.length > 64) continue;
      if (id.isEmpty || id.length > 256) continue;
      if (!_tombstoneEntityTypes.contains(type)) continue;
      final forType = out.putIfAbsent(type, () => {});
      final existing = forType[id];
      if (existing == null || at.isAfter(existing)) forType[id] = at;
    }
    return out;
  }

  /// Whether a tombstone outranks a record with [updatedAt] - i.e. the record
  /// should NOT be (re)stored. "Newest wins": outranked when the tombstone's
  /// deletedAt is not older than [updatedAt]. A record with no [updatedAt] (a
  /// timestamp-less table) is delete-wins: outranked whenever a tombstone
  /// exists.
  static bool _tombstoneOutranks(Map<String, Map<String, DateTime>> tombstones,
      String type, String id, DateTime? updatedAt) {
    final deletedAt = tombstones[type]?[id];
    if (deletedAt == null) return false;
    if (updatedAt == null) return true; // delete-wins
    return !updatedAt.isAfter(deletedAt); // deletedAt >= updatedAt
  }

  /// How far ahead of this device's clock a delete's time may be and still
  /// be taken as written: what two clocks that are both about right differ by.
  static const tombstoneClockAllowance = Duration(minutes: 10);

  /// Whether this device's clock is known to be wrong: the store said what
  /// time it is, and it is not the time here (AutoSyncService, which warns the
  /// person). While it is, [gatherAll] prunes no tombstone.
  bool clockInDoubt = false;

  /// Union the blob's tombstones with the local set (newest deletedAt per id),
  /// persisting any the blob adds so this device re-propagates them, and return
  /// the merged lookup.
  ///
  /// A delete dated ahead of now (by more than [tombstoneClockAllowance]) was
  /// made by a clock that was wrong, at some time before now. Taken as
  /// written, it outranked every later change of the item on every device
  /// until its date came: a host restored from a backup, or made again, was
  /// deleted again at each sync (found in a security audit). It is held to
  /// now instead, once: where this device holds a tombstone of the item
  /// already, that one stays, else each pull would move it to that pull's
  /// now and it would outrank every change again. One this device holds
  /// dated ahead (taken before this rule, or written while its own clock was
  /// ahead) is put back to now the same way.
  Future<Map<String, Map<String, DateTime>>> _mergeTombstones(
      dynamic raw) async {
    final now = DateTime.now();
    final latest = now.add(tombstoneClockAllowance);
    final merged = await _tombstonesHere(now);
    final incoming = _parseTombstones(raw);
    for (final typeEntry in incoming.entries) {
      final forType = merged.putIfAbsent(typeEntry.key, () => {});
      for (final idEntry in typeEntry.value.entries) {
        final existing = forType[idEntry.key];
        final ahead = idEntry.value.isAfter(latest);
        final at = ahead ? now : idEntry.value;
        if (existing == null || (!ahead && at.isAfter(existing))) {
          forType[idEntry.key] = at;
          await _database.tombstonesDao.mark(typeEntry.key, idEntry.key, at: at);
        }
      }
    }
    return merged;
  }

  /// This device's tombstones, by kind and id. One dated ahead of [now] (by
  /// more than [tombstoneClockAllowance]) is put back to [now], here and in
  /// the database ([_mergeTombstones]).
  Future<Map<String, Map<String, DateTime>>> _tombstonesHere(DateTime now) async {
    final latest = now.add(tombstoneClockAllowance);
    final here = <String, Map<String, DateTime>>{};
    for (final t in await _database.tombstonesDao.getAll()) {
      var at = t.deletedAt;
      if (at.isAfter(latest)) {
        at = now;
        await _database.tombstonesDao.mark(t.entityType, t.entityId, at: now);
      }
      (here[t.entityType] ??= {})[t.entityId] = at;
    }
    return here;
  }

  /// Drop blob records a tombstone outranks IN PLACE, so the restore blocks
  /// below never re-add a deleted record (newest-wins). Local records a
  /// tombstone outranks are removed separately by [_applyTombstoneDeletions].
  void _suppressTombstonedRecords(
      Map<String, dynamic> data, Map<String, Map<String, DateTime>> tombstones) {
    if (tombstones.isEmpty) return;
    for (final (blobKey, type, idField) in _tombstonedKinds) {
      final list = data[blobKey];
      if (list is! List) continue;
      list.removeWhere((e) {
        if (e is! Map) return false;
        final id = _str(e[idField]);
        if (id.isEmpty) return false;
        return _tombstoneOutranks(
            tombstones, type, id, _flexDateTime(e['updatedAt']));
      });
    }
  }

  /// The kinds a tombstone can delete, each as (blob key, entity type, id
  /// field). The blob key and the entity type are also the table's name, and
  /// the id field its column's.
  static const _tombstonedKinds = [
    ('connections', 'connections', 'id'),
    ('connection_groups', 'connection_groups', 'id'),
    ('identities', 'identities', 'id'),
    ('snippets', 'snippets', 'id'),
    ('snippet_categories', 'snippet_categories', 'name'),
    ('networks', 'networks', 'id'),
    ('port_forward_rules', 'port_forward_rules', 'id'),
    ('terminal_triggers', 'terminal_triggers', 'id'),
    ('command_history', 'command_history', 'id'),
    ('host_network_overrides', 'host_network_overrides', 'id'),
    ('port_forward_network_overrides', 'port_forward_network_overrides', 'id'),
  ];

  /// The records of [data] (a backup) that one of this device's own
  /// [tombstones] outranks: what was deleted here after the backup was made,
  /// which it brings back. Each as its table, the column naming its row, its
  /// id, and when it was deleted.
  static List<(String, String, String, DateTime)> _deletedHereSince(
      Map<String, dynamic> data, Map<String, Map<String, DateTime>> tombstones) {
    final out = <(String, String, String, DateTime)>[];
    for (final (blobKey, type, idField) in _tombstonedKinds) {
      final list = data[blobKey];
      if (list is! List) continue;
      for (final e in list) {
        if (e is! Map) continue;
        final id = _str(e[idField]);
        if (id.isEmpty) continue;
        if (_tombstoneOutranks(tombstones, type, id, _flexDateTime(e['updatedAt']))) {
          out.add((type, idField, id, tombstones[type]![id]!));
        }
      }
    }
    return out;
  }

  /// Remove every LOCAL record a tombstone outranks (newest-wins). Runs at the
  /// END of the restore transaction. Uses a raw table delete (no re-marking):
  /// for tables WITH `updatedAt` the delete is guarded so an edit newer than
  /// the tombstone survives; timestamp-less tables are delete-wins.
  Future<void> _applyTombstoneDeletions(
      Map<String, Map<String, DateTime>> tombstones) async {
    final db = _database;
    for (final typeEntry in tombstones.entries) {
      final type = typeEntry.key;
      for (final idEntry in typeEntry.value.entries) {
        final id = idEntry.key;
        final deletedAt = idEntry.value;
        switch (type) {
          // Tables WITH updatedAt → newest-wins.
          case 'connections':
            await (db.delete(db.connections)..where((t) =>
                    t.id.equals(id) &
                    t.updatedAt.isSmallerOrEqualValue(deletedAt)))
                .go();
          case 'snippets':
            await (db.delete(db.snippets)..where((t) =>
                    t.id.equals(id) &
                    t.updatedAt.isSmallerOrEqualValue(deletedAt)))
                .go();
          case 'host_network_overrides':
            await (db.delete(db.hostNetworkOverrides)..where((t) =>
                    t.id.equals(id) &
                    t.updatedAt.isSmallerOrEqualValue(deletedAt)))
                .go();
          case 'port_forward_network_overrides':
            await (db.delete(db.portForwardNetworkOverrides)..where((t) =>
                    t.id.equals(id) &
                    t.updatedAt.isSmallerOrEqualValue(deletedAt)))
                .go();
          // Tables that gained `updatedAt` at v29 → newest-wins. A null
          // updated_at (a row never edited on v29+) is treated as very old →
          // delete-wins.
          case 'connection_groups':
            await (db.delete(db.connectionGroups)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'identities':
            await (db.delete(db.identities)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'networks':
            await (db.delete(db.networks)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'port_forward_rules':
            await (db.delete(db.portForwardRules)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'terminal_triggers':
            await (db.delete(db.terminalTriggers)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'command_history':
            await (db.delete(db.commandHistory)..where((t) =>
                    t.id.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
          case 'snippet_categories':
            await (db.delete(db.snippetCategories)..where((t) =>
                    t.name.equals(id) &
                    (t.updatedAt.isSmallerOrEqualValue(deletedAt) |
                        t.updatedAt.isNull())))
                .go();
        }
      }
    }
    // Any connection removed above (or earlier) leaves its tags orphaned -
    // connection_tags has no cascade FK. Sweep them so a deleted host's tags
    // don't linger, get re-emitted into the sync blob, and surface as ghost
    // tags whose filters match no visible host.
    await db.customStatement(
      'DELETE FROM connection_tags WHERE connection_id NOT IN '
      '(SELECT id FROM connections)',
    );
    // The same for a host's other accounts (no foreign keys either), and for
    // an identity removed above, which leaves the accounts of every host.
    await db.customStatement(
      'DELETE FROM host_accounts WHERE connection_id NOT IN (SELECT id FROM connections) '
      'OR identity_id NOT IN (SELECT id FROM identities)',
    );
  }

  /// Assess whether merging [cloudData] into this device would resurrect
  /// records the cloud has already forgotten. Returns the per-entity set of
  /// LOCAL row ids that are (a) absent from the cloud blob AND (b) not covered
  /// by a cloud tombstone.
  ///
  /// On a device that synced recently this is the ordinary "created here, not
  /// pushed yet" set and is pushed as usual. On a device offline longer than
  /// [kTombstoneRetention] the cloud's tombstones for these ids may have been
  /// GC'd (see the retention prune in [gatherAll]), so the set is AMBIGUOUS -
  /// each id is either a genuine local creation or an item deleted on another
  /// device long ago whose tombstone has since expired. The sync cycle uses
  /// this to stop and ask before pushing, instead of silently re-inserting the
  /// deleted items back into everyone's cloud.
  Future<StaleReconcileReport> assessStaleReconcile(
      Map<String, dynamic> cloudData) async {
    // FTPS hosts (3.4) with the others; where an older version wrote the
    // store (no `ftps_hosts` at all), they are not in it by its doing, not
    // because they were deleted, and are left out of what is asked about.
    final ftpsHostsHeld = cloudData.containsKey(ftpsHostsKey);
    // Remote screens (4.0) the same: a store a version before them wrote
    // has no `screen_hosts`, which does not mean they were deleted.
    final screenHostsHeld = cloudData.containsKey(screenHostsKey);
    // RDP hosts (4.0) the same, with `rdp_hosts`.
    final rdpHostsHeld = cloudData.containsKey(rdpHostsKey);
    cloudData = withHostListsJoined(cloudData);
    final tombstones = _parseTombstones(cloudData['tombstones']);
    final report = <String, List<String>>{};

    Future<void> diff(
        String type, Future<List<String>> Function() localIds) async {
      final cloudIds = <String>{};
      final list = cloudData[type];
      if (list is List) {
        for (final e in list) {
          if (e is Map) {
            final id = _str(e['id']);
            if (id.isNotEmpty) cloudIds.add(id);
          }
        }
      }
      final tomb = tombstones[type]?.keys.toSet() ?? const <String>{};
      final locals = await localIds();
      final only = [
        for (final id in locals)
          if (!cloudIds.contains(id) && !tomb.contains(id)) id
      ];
      if (only.isNotEmpty) report[type] = only;
    }

    // Only the user-recognizable entities - the ones worth naming in the
    // reconcile prompt. Child override tables ride their parent connection.
    await diff('connections', () async => [
          for (final e in await _connectionsDao.getAll())
            if ((ftpsHostsHeld || !ConnectionProtocol.storedIsFtps(e.protocol)) &&
                (screenHostsHeld ||
                    ConnectionProtocol.kindClassOf(e.protocol) != ConnectionProtocol.kindClassScreen) &&
                (rdpHostsHeld || ConnectionProtocol.kindClassOf(e.protocol) != ConnectionProtocol.kindClassRdp))
              e.id.toString(),
        ]);
    await diff('identities', () async =>
        (await _identitiesDao.getAll()).map((e) => e.id.toString()).toList());
    await diff('connection_groups', () async =>
        (await _groupsDao.getAll()).map((e) => e.id.toString()).toList());
    await diff('snippets', () async =>
        (await _snippetsDao.getAll()).map((e) => e.id.toString()).toList());
    await diff('networks', () async =>
        (await _networksDao.getAll()).map((e) => e.id.toString()).toList());
    await diff('port_forward_rules', () async =>
        (await _portForwardRulesDao.getAll())
            .map((e) => e.id.toString())
            .toList());
    return StaleReconcileReport(report);
  }

  /// Delete exactly the local-only rows named in [report] (the ambiguous set
  /// from [assessStaleReconcile]) so this device MATCHES the cloud - the
  /// "Adopt cloud" outcome of the stale-device reconcile.
  ///
  /// These deletes are tombstone-FREE on purpose: adopting the cloud is a
  /// per-device decision to stop carrying rows the cloud no longer has, NOT a
  /// delete command to broadcast. The ids exist only on this device, so a
  /// propagating tombstone would be a no-op on every other device and would
  /// misrepresent the user's intent (they chose to defer to the cloud, not to
  /// order a fleet-wide delete).
  Future<void> dropLocalOnly(StaleReconcileReport report) async {
    final db = _database;
    Future<void> drop(String type) async {
      final ids = report.localOnlyIds[type];
      if (ids == null || ids.isEmpty) return;
      switch (type) {
        case 'connections':
          // Clear child rows that would otherwise dangle. Any that are
          // themselves local-only are also in the report and dropped by their
          // own branch; this covers children of a dropped parent regardless.
          await (db.delete(db.portForwardRules)
                ..where((t) => t.connectionId.isIn(ids)))
              .go();
          await (db.delete(db.hostNetworkOverrides)
                ..where((t) => t.connectionId.isIn(ids)))
              .go();
          await (db.delete(db.connections)..where((t) => t.id.isIn(ids))).go();
        case 'identities':
          // Their secrets go after the rows are gone (below), as in
          // restoreAll.
          await (db.delete(db.identities)..where((t) => t.id.isIn(ids))).go();
          // What named them names them no more.
          await db.hostAccountsDao.forgetMissingIdentities();
        case 'connection_groups':
          await (db.delete(db.connectionGroups)..where((t) => t.id.isIn(ids)))
              .go();
        case 'snippets':
          await (db.delete(db.snippets)..where((t) => t.id.isIn(ids))).go();
        case 'networks':
          await (db.delete(db.networks)..where((t) => t.id.isIn(ids))).go();
        case 'port_forward_rules':
          await (db.delete(db.portForwardRules)..where((t) => t.id.isIn(ids)))
              .go();
      }
    }

    // The rows in one transaction, and only then the keys' secrets, through
    // the store that keeps them (3.4.2 sweep, L11: the secrets went first,
    // one by one, by their raw names, so a failure part way left keys listed
    // with their secrets gone). A secret that is not deleted now is one with
    // no key, which the sweep of secrets with no key takes.
    await db.transaction(() async {
      for (final type in report.localOnlyIds.keys) {
        await drop(type);
      }
    });
    for (final id in report.localOnlyIds['identities'] ?? const <String>[]) {
      try {
        await _identitySecrets.deleteAll(id);
      } catch (e) {
        AppLogger.warning('A dropped key\'s secrets were left for the sweep: ${errorKind(e)}');
      }
    }
  }

  /// What restoring [data] (a backup) would do, said before anything is
  /// written ([RestorePreview]): what it holds, what it writes over here, and
  /// the hosts it brings, new or changed, that do something by themselves.
  Future<RestorePreview> previewRestore(Map<String, dynamic> data) async {
    // Any key: only whether two copies are the same is asked.
    const key = [0x72, 0x65, 0x73, 0x74, 0x6f, 0x72, 0x65];
    final hereHashes = itemHashes(await gatherAll(), key);
    final thereHashes = itemHashes(data, key);
    var hosts = 0, keys = 0, snippets = 0, other = 0, replaces = 0;
    final acting = <(String, Set<HostActsAlone>)>[];
    // A forward set On for a network starts by itself: a remote one lets its
    // host reach whatever this device can.
    final hostOfForward = {
      for (final r in (data['port_forward_rules'] is List ? data['port_forward_rules'] as List : const []))
        if (r is Map) _str(r['id']): _str(r['connectionId']),
    };
    final startsForward = {
      for (final o in (data['port_forward_network_overrides'] is List ? data['port_forward_network_overrides'] as List : const []))
        if (o is Map && _str(o['state']) == 'on') hostOfForward[_str(o['ruleId'])],
    };
    for (final item in _itemsOf(data)) {
      final kind = item.name.substring(0, item.name.indexOf('/'));
      switch (kind) {
        case 'connections':
          hosts++;
        case 'identities':
          keys++;
        case 'snippets':
          snippets++;
        default:
          other++;
      }
      final mine = hereHashes[item.name];
      final changed = mine != thereHashes[item.name];
      if (mine != null && changed) replaces++;
      final row = item.row;
      final starts = kind == 'connections' && startsForward.contains(_str(row['id']));
      if (kind != 'connections' || (!changed && !starts)) continue;
      final runs = _str(row['startupCommand']).trim().isNotEmpty;
      final runsSnippet = _str(row['snippetId']).isNotEmpty;
      final sets = _sanitizeEnvVars(_str(row['envVars'] ?? '')).isNotEmpty;
      // A local shell's commands run on this computer, as whoever opens it.
      final here = _str(row['protocol']) == 'localShell';
      final acts = {
        if (here && (runs || runsSnippet || sets)) HostActsAlone.runsHere,
        if (!here && runs) HostActsAlone.runsCommand,
        if (!here && runsSnippet) HostActsAlone.runsSnippet,
        if (!here && sets) HostActsAlone.setsVariables,
        if (starts) HostActsAlone.startsForward,
        if (_bool(row['forwardAgent'])) HostActsAlone.forwardsAgent,
        if (_bool(row['monitored'])) HostActsAlone.monitored,
        if (_bool(row['compatibilityMode'])) HostActsAlone.compatibilityMode,
      };
      if (acts.isNotEmpty) acting.add((_str(row['label']), acts));
    }
    // The hosts whose keys it would trust that this device has not confirmed:
    // each would connect the first time with a passing notice, not a question
    // (found in a security review).
    // Each with its route: a key for a host reached through a jump host is
    // that route's, and is named so (found in a security review).
    final hostKeys = <RestoreHostKey>{};
    if (data['known_hosts'] is List) {
      final now = DateTime.now();
      for (final h in data['known_hosts'] as List) {
        final adopt = (await _mergedHostKey(h, now))?.adopt;
        if (adopt == null) continue;
        final host = adopt.host.value;
        final via = adopt.viaScope.present ? adopt.viaScope.value : null;
        hostKeys.add(RestoreHostKey(host.contains(':') ? '[$host]:${adopt.port.value}' : '$host:${adopt.port.value}',
            via: via == null || via.isEmpty ? null : via));
      }
    }
    final settings = data['settings'];
    return RestorePreview(
      hosts: hosts,
      keys: keys,
      snippets: snippets,
      other: other,
      replaces: replaces,
      acting: acting,
      weakens: settings is Map ? settingsThatWeaken(settings) : const [],
      hostKeys: hostKeys.toList(),
    );
  }

  /// The keys of [settings], from a backup, that would turn down safety here
  /// ([SettingsService.settingsThatWeaken]).
  List<String> settingsThatWeaken(Map<dynamic, dynamic> settings) => _settingsService.settingsThatWeaken(settings);

  /// What a merge does with one host key of a blob, [h] (restoreAll, and the
  /// restore preview, which names what it would trust): null when nothing,
  /// [conflict] ("host:port") when this device trusts another key of that type
  /// there, otherwise the row it adopts ([adopt]).
  Future<({KnownHostsCompanion? adopt, String? conflict})?> _mergedHostKey(Object? h, DateTime now) async {
    if (h is! Map) return null;
    final map = Map<String, dynamic>.from(h);
    final id = _str(map['id']);
    if (id.isEmpty || id.length > 128) return null;
    final host = _capText(_str(map['host']), 255);
    final keyType = _capText(_str(map['keyType']), 64);
    final fingerprint = _capText(_str(map['fingerprint']), 255);
    final pub = _str(map['publicKeyBase64']);
    if (host.isEmpty || keyType.isEmpty || fingerprint.isEmpty || pub.isEmpty) return null;
    final port = _clampInt(map['port'], 0, 65535);
    final firstSeen = _flexDateTime(map['firstSeen']) ?? now;
    final recordedDevice = _capTextOpt(map['recordedDevice'], 255);
    // Route scope (blob v13/DB v32): NULL for direct connections, so
    // pre-scope blobs restore unchanged; a scoped record stays SEPARATE
    // from the same host:port reached directly or via another jump.
    final viaScope = _capTextOpt(map['viaScope'], 255);

    final existing = await _knownHostsDao.findHost(host, port, keyType, viaScope: viaScope);
    if (existing != null) {
      if (existing.fingerprint == fingerprint) return null; // agreeing
      // Conflict: two devices disagree on this host's key. Keep local,
      // trust neither the other one nor both; report it.
      return (adopt: null, conflict: '$host:$port');
    }
    // New for this device. Auto-adopt only with provenance + a past
    // recorded-at; otherwise leave the host unknown (normal TOFU on
    // connect) rather than trust an unprovenanced injection.
    if (recordedDevice == null || recordedDevice.isEmpty || !firstSeen.isBefore(now)) return null;
    // A key new to this device, for a host this device confirmed itself with
    // another key, on this route or any other (direct, or through any jump
    // host): not adopted. A crafted backup could otherwise add a second key
    // type for a trusted host, or a key for it reached through a jump host,
    // and a man in the middle offering only that key would pass with a
    // passing notice. A connect that meets it asks as a changed key, as it
    // would had the row not come (on any route; found in a security
    // review). The very
    // key this device confirmed, kept for another route, is no new trust.
    // Rows a merge adopts are not confirmed here, so a host new to this
    // device takes every key it brings.
    final heldHere = await _knownHostsDao.findAllForHostPortAnyRoute(host, port);
    if (heldHere.any((r) => r.locallyVerified && r.fingerprint != fingerprint)) return null;
    // The id may already name this device's record of another route:
    // the first connect through a jump host moves a synced direct
    // record to that route under the same id, while the other device
    // still has it as direct. Inserting it again under that id failed
    // every merge from then on (UNIQUE constraint failed:
    // known_hosts.id), so this route's trust is adopted under a new id.
    final idTaken = await _knownHostsDao.getById(id) != null;
    return (
      adopt: KnownHostsCompanion(
        id: Value(idTaken ? const Uuid().v4() : id),
        host: Value(host),
        port: Value(port),
        keyType: Value(keyType),
        fingerprint: Value(fingerprint),
        publicKeyBase64: Value(pub),
        firstSeen: Value(firstSeen),
        lastSeen: Value(_flexDateTime(map['lastSeen']) ?? firstSeen),
        recordedDevice: Value(recordedDevice),
        locallyVerified: const Value(false),
        viaScope: Value(viaScope),
      ),
      conflict: null,
    );
  }

  /// With [merge] (a pull of sync, 3.0), each item this device has as well
  /// is merged three ways with what this device last synced: one changed
  /// only there is taken, one changed only here is kept (the next push sends
  /// it: [SyncRestoreResult.keptHere]), one that is the same is left as it
  /// is, and one changed on both sides goes to the later change (the other
  /// devices' copy where that cannot be told). Either way a row written keeps
  /// the time of change [data] gives it: none is stamped as changed now by
  /// the restore. (Every pull took every item of the store over this device's
  /// own, so a change made here was undone by the next pull whenever another
  /// device had synced meanwhile; and a pull stamped the rows it rewrote
  /// unchanged as changed then, so a delete made elsewhere before that never
  /// applied here, and this device sent the item back to the others.)
  ///
  /// Without (joining sync, with the sync password, a recovery key or another
  /// device's approval; an older version's data), there is no base to merge
  /// with ([SyncMergeBase.noBase]): of two copies of an item that differ, the
  /// one changed later stands where its time of change can be trusted (a
  /// host, a snippet), and the incoming one otherwise. Every item of [data]
  /// was written over this device's own, so a host edited here while sync was
  /// off went back to the store's older copy at the join, with nothing said,
  /// and the next push sent the old copy everywhere (found in a data
  /// review). What is kept here is counted
  /// ([SyncRestoreResult.keptHere]) for the push that follows.
  ///
  /// [asBackup]: [data] is a backup (BackupService.importBackup), which only
  /// adds and writes over: it deletes nothing here, and what it holds comes
  /// back though it was deleted here since. Its tombstones are not taken (they
  /// deleted the hosts here that the device it was made on had deleted once,
  /// and stayed to delete them at every pull after), and this device's own do
  /// not keep its records out (a backup could not bring back what was deleted
  /// by mistake, the very thing a restore is for).
  /// A record it brings back that was deleted here is written
  /// as changed now, so that the deletion, which other devices hold too, does
  /// not remove it again at the next sync on any device.
  Future<SyncRestoreResult> restoreAll(Map<String, dynamic> data, {SyncMergeBase? merge, bool asBackup = false}) async {
    // FTPS hosts (3.4) and remote screens (4.0) are restored as the hosts
    // they are.
    data = withHostListsJoined(data);
    // Only a backup writes every item it holds over this device's own.
    merge ??= asBackup ? null : SyncMergeBase.noBase;
    int restored = 0;
    final knownHostConflicts = <String>[];

    // Refuse a blob written by a NEWER client: an older build silently strips
    // fields it doesn't know and would push the truncated data back, causing
    // data loss for every device. Fail closed and tell the user to update.
    final blobSchema = _intOpt(data['schema_version']) ?? 0;
    if (blobSchema > supportedSchemaVersion) {
      AppLogger.warning(
          'Sync restore refused: blob schema_version $blobSchema exceeds '
          'supported $supportedSchemaVersion');
      return const SyncRestoreResult(
        success: false,
        recordsRestored: 0,
        error: 'This sync data was written by a newer version of ZestSSH. '
            'Update the app to sync with this account.',
      );
    }

    // This device's items as they are before anything is written: when each
    // was last changed, and, for a pull, what each holds.
    //
    // The reading takes a while (every table, then the secrets of every key)
    // and is done before the transaction that writes, so the database stays
    // free for the screens meanwhile. But an edit saved in that gap was
    // judged by what had been read before it, and where another device had
    // changed the same item it was written over with nothing said (found in a code
    // audit). So the transaction asks first whether anything was
    // written to the database since the reading began, and reads this device
    // again, inside itself, where something was: from then on nothing can be
    // saved until the pull has written, and what is saved after lands on top
    // of it.
    final writesBefore = await _writesSoFar();
    var here = await gatherAll();
    var hereAt = _changeTimes(here);
    var hereHashes = merge == null ? null : itemHashes(here, merge.key);
    // What cannot be read of this device at the second reading (a key's
    // secret that does not open) is thrown on as at the first, not answered
    // as a restore that failed.
    Object? unread;
    final thereHashes = merge == null ? null : itemHashes(data, merge.key);
    var keptHere = 0;
    final taken = <String>{};
    // Taken because only the other devices changed them since this one last
    // synced: what they took off goes here too (a key's saved password).
    final changedThere = <String>{};
    final sftpOnlyTurnedBack = <String>{};
    final sftpOnlyAgain = <String>{};

    SyncTake take(String item, DateTime? thereAt) {
      if (merge == null) return SyncTake.incoming;
      final mine = hereHashes![item];
      final theirs = thereHashes![item];
      // A setting carries no time, so what a store that went back holds of it
      // cannot be told for a change: this device's stays, and goes back to the
      // store. (A restored store turned security switches such as OSC 52 back
      // on every device that synced, whatever they had been set to since: the
      // cryptography audit.)
      if (merge.storeWentBack && item.startsWith('settings/')) {
        return mine == theirs ? SyncTake.same : SyncTake.local;
      }
      if (mine == null || theirs == null) return SyncTake.incoming;
      if (mine == theirs) return SyncTake.same;
      final mineAt = hereAt[item];
      if (merge.lastChanged) {
        // Two copies with no history in common: the one changed last stands, and
        // here where that cannot be told, so nothing older takes the place of what
        // is here. A key whose secrets are still owed from a Bring that stopped
        // goes again, where nothing has changed it since: it holds another secret
        // only because that one never arrived.
        if (thereAt != null && (mineAt == null || thereAt.isAfter(mineAt))) return SyncTake.incoming;
        if (merge.owed.contains(item) && mineAt == thereAt) return SyncTake.incoming;
        return SyncTake.local;
      }
      final was = merge.base?[item];
      if (was == mine) {
        // Unchanged here since the last sync: the store's copy is another
        // device's change, and is taken. But a store that went back (restored
        // from a backup) holds older copies than this device's, and an older
        // copy is no change: this device's later one is kept, and sent back.
        // What was edited after the backup went back to how it was then, on
        // every device that synced (found in the client's
        // security review). One with no time to tell by is kept too.
        if (merge.storeWentBack && (mineAt == null || thereAt == null || mineAt.isAfter(thereAt))) {
          return SyncTake.local;
        }
        if (!merge.storeWentBack) changedThere.add(item);
        return SyncTake.incoming;
      }
      if (was == theirs) return SyncTake.local;
      // Changed on both sides, or no base yet: the later change wins, where
      // the times of change can be trusted; the other devices' copy otherwise.
      final trusted = merge.base != null || _timesKept.contains(item.substring(0, item.indexOf('/')));
      if (trusted && mineAt != null && thereAt != null && mineAt.isAfter(thereAt)) return SyncTake.local;
      return SyncTake.incoming;
    }

    /// Whether [item] is written from [data]; one kept here is counted.
    bool fromThere(String item, Object? updatedAt) {
      final decided = take(item, _flexDateTime(updatedAt));
      if (decided == SyncTake.local) keptHere++;
      if (decided != SyncTake.incoming) return false;
      taken.add(item);
      return true;
    }

    /// A row written with the time of change it had already is stamped as
    /// changed now by the database ([_createUpdatedAtTriggers]): that time is
    /// put back.
    Future<void> keepTime(String table, String key, String item, String id, Object? updatedAt) async {
      final there = _flexDateTime(updatedAt);
      final before = hereAt[item];
      if (there == null || before == null) return;
      final seconds = there.millisecondsSinceEpoch ~/ 1000;
      if (seconds != before.millisecondsSinceEpoch ~/ 1000) return;
      await _database.customStatement('UPDATE $table SET updated_at = ? WHERE $key = ?', [seconds, id]);
    }

    try {
      await _database.transaction(() async {
        // The first statement of the transaction: whatever was saved before
        // it is counted, and nothing is saved after it until the end.
        if (await _writesSoFar() != writesBefore) {
          try {
            here = await gatherAll();
          } catch (e) {
            unread = e;
            rethrow;
          }
          hereAt = _changeTimes(here);
          hereHashes = merge == null ? null : itemHashes(here, merge.key);
        }

        // ── Tombstones (delete-propagation) ───────────────────────
        // Merge the blob's delete markers into the local set, then drop any
        // blob record a tombstone outranks so the restore below can't re-add a
        // deleted record (newest-wins). LOCAL records a tombstone outranks are
        // removed by _applyTombstoneDeletions at the end of the transaction.
        final Map<String, Map<String, DateTime>> tombstones;
        final List<(String, String, String, DateTime)> broughtBack;
        if (asBackup) {
          // (One dated ahead is put back to now first: a record brought back
          // is written as changed after its deletion, and would be dated
          // ahead itself.)
          final here = await _tombstonesHere(DateTime.now());
          broughtBack = _deletedHereSince(data, here);
          tombstones = const {};
        } else {
          broughtBack = const [];
          tombstones = await _mergeTombstones(data['tombstones']);
          _suppressTombstonedRecords(data, tombstones);
        }

        // Restore connection groups first (connections reference them)
        if (data['connection_groups'] is List) {
          final groups = data['connection_groups'] as List;
          for (final g in groups) {
            if (g is! Map) continue;
            final map = Map<String, dynamic>.from(g);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id
            // The name is held to what the table takes (1 to 255): one of 256
            // was let through and one of none too, and either threw at the
            // write and took the whole restore with it, as a snippet's did
            // before (found in a security audit).
            final groupName = _capText(_str(map['name']), 255);
            if (groupName.isEmpty) continue;
            if (!fromThere('connection_groups/$id', map['updatedAt'])) continue;
            final existing = await _groupsDao.getById(id);
            // colorIndex is nullable by design (null = legacy
            // name-hash color) and absent entirely in blobs from
            // pre-v17 builds - both decode to null here. Clamp when present
            // so a negative/huge value can't crash the pill-bar palette lookup.
            final colorIndex =
                map['colorIndex'] == null ? null : _clampInt(map['colorIndex'], 0, 63);
            // iconCodePoint is nullable by design (null = default folder
            // glyph) and absent entirely in blobs from pre-v21 builds -
            // both decode to null here. Clamp when present so a corrupt
            // value can't blow up the const-IconData catalog lookup (it
            // falls back to the default icon regardless).
            final iconCodePoint = map['iconCodePoint'] == null
                ? null
                : _clampInt(map['iconCodePoint'], 0, 0x10FFFF);
            final sortOrder = _clampInt(map['sortOrder'], 0, 1000000000);
            if (existing != null) {
              await _groupsDao.updateGroup(ConnectionGroupsCompanion(
                id: Value(id),
                name: Value(groupName),
                sortOrder: Value(sortOrder),
                isExpanded: Value(_bool(map['isExpanded'])),
                colorIndex: Value(colorIndex),
                colorValue: Value(_intOpt(map['colorValue'])),
                iconCodePoint: Value(iconCodePoint),
                // Preserve real modification time for tombstone newest-wins.
                updatedAt: Value(_flexDateTime(map['updatedAt'])),
              ));
            } else {
              await _groupsDao.insertGroup(ConnectionGroupsCompanion(
                id: Value(id),
                name: Value(groupName),
                sortOrder: Value(sortOrder),
                isExpanded: Value(_bool(map['isExpanded'])),
                createdAt: Value(_dateTime(map['createdAt'])),
                colorIndex: Value(colorIndex),
                colorValue: Value(_intOpt(map['colorValue'])),
                iconCodePoint: Value(iconCodePoint),
                updatedAt: Value(_flexDateTime(map['updatedAt'])),
              ));
            }
            await keepTime('connection_groups', 'id', 'connection_groups/$id', id, map['updatedAt']);
            restored++;
          }
        }

        // Restore identities (connections reference them)
        if (data['identities'] is List) {
          final identities = data['identities'] as List;
          for (final i in identities) {
            if (i is! Map) continue;
            final map = Map<String, dynamic>.from(i);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id
            // Label and user name are held to what the table takes (1 to 255
            // each): 512 and 256 were let through, and an empty one too, and
            // the write threw and took the whole restore with it (found in a security
            // audit). A key with no user name is no key to sign
            // in with; one with no label is named by its user name.
            final keyUsername = _capText(_str(map['username']), 255);
            if (keyUsername.isEmpty) continue;
            final keyLabelGiven = _capText(_str(map['label']), 255);
            final keyLabel = keyLabelGiven.trim().isEmpty ? keyUsername : keyLabelGiven;
            if (!fromThere('identities/$id', map['updatedAt'])) continue;
            final existing = await _identitiesDao.getById(id);
            // Whitelist authMethod + cap/strip the remaining free-text fields
            // (keyType/fingerprint/publicKeyData) the way label/username are.
            final authMethod = _validateAuthMethod(map['authMethod']);
            final keyType = _capTextOpt(map['keyType'], 64);
            final fingerprint = _capTextOpt(map['publicKeyFingerprint'], 128);
            final publicKeyData = _capTextOpt(map['publicKeyData'], 8192);
            // `usesAgent` IS synced (see the serialize note above) so an
            // agent-backed identity stays agent-backed across devices. The
            // device-specific `agentSocketPath` and the cert* mirror cache are
            // intentionally NOT restored (device-local); leaving them absent
            // keeps the serialize/restore field sets identical so the
            // round-trip fingerprint is stable.
            if (existing != null) {
              await _identitiesDao.updateIdentity(IdentitiesCompanion(
                id: Value(id),
                label: Value(keyLabel),
                username: Value(keyUsername),
                authMethod: Value(authMethod),
                keyType: Value(keyType),
                publicKeyFingerprint: Value(fingerprint),
                publicKeyData: Value(publicKeyData),
                colorIndex: Value(_clampInt(map['colorIndex'], 0, 63)),
                colorValue: Value(_intOpt(map['colorValue'])),
                isDefault: Value(_bool(map['isDefault'])),
                usesAgent: Value(_bool(map['usesAgent'])),
                agentSource: Value(_validateAgentSource(map['agentSource'])),
                passwordRef: Value(_validatePasswordRef(map['passwordRef'])),
                // Whether its saved password is tried after its key (blob 22).
                passwordAfterKey: Value(_bool(map['passwordAfterKey'])),
                // Preserve real modification time for tombstone newest-wins.
                updatedAt: Value(_flexDateTime(map['updatedAt'])),
              ));
            } else {
              await _identitiesDao.insertIdentity(IdentitiesCompanion(
                id: Value(id),
                label: Value(keyLabel),
                username: Value(keyUsername),
                authMethod: Value(authMethod),
                keyType: Value(keyType),
                publicKeyFingerprint: Value(fingerprint),
                publicKeyData: Value(publicKeyData),
                colorIndex: Value(_clampInt(map['colorIndex'], 0, 63)),
                colorValue: Value(_intOpt(map['colorValue'])),
                isDefault: Value(_bool(map['isDefault'])),
                usesAgent: Value(_bool(map['usesAgent'])),
                agentSource: Value(_validateAgentSource(map['agentSource'])),
                passwordRef: Value(_validatePasswordRef(map['passwordRef'])),
                // Whether its saved password is tried after its key (blob 22).
                passwordAfterKey: Value(_bool(map['passwordAfterKey'])),
                createdAt: Value(_dateTime(map['createdAt'])),
                updatedAt: Value(_flexDateTime(map['updatedAt'])),
              ));
            }
            await keepTime('identities', 'id', 'identities/$id', id, map['updatedAt']);
            restored++;
          }
        }

        // Restore connections
        if (data['connections'] is List) {
          final connections = data['connections'] as List;
          for (final c in connections) {
            if (c is! Map) continue;
            final map = Map<String, dynamic>.from(c);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id

            // Validate critical fields from untrusted backup data.
            final host = _validateHost(map['host']);
            if (host == null) {
              AppLogger.warning(
                  'Restore: skipping connection $id - invalid host');
              continue;
            }
            final port = _validatePort(map['port']);
            if (port == null) {
              AppLogger.warning(
                  'Restore: skipping connection $id - invalid port');
              continue;
            }
            final protocol = _validateProtocol(map['protocol']);
            final envVars = _sanitizeEnvVars(_str(map['envVars'] ?? ''));

            // Sanitise startupCommand: reject null bytes and cap length.
            String? startupCmd = _strOpt(map['startupCommand']);
            if (startupCmd != null) {
              if (startupCmd.contains('\x00') || startupCmd.length > 4096) {
                startupCmd = null;
              }
            }

            // Sanitise the Part B free-text `note` - same untrusted blob,
            // rendered on host cards. Truncate (don't null) so a long note
            // degrades gracefully instead of vanishing on the next sync.
            // (`label` and the other free-text fields are bounded inline via
            // `_capText` at each write site - a multi-MB label/name is a
            // render DoS, and the host itself is already control-char
            // validated so a spoofy label mustn't ride alongside it.)
            String? note = _capTextOpt(map['note'], 4096);
            if (note != null && note.isEmpty) note = null;

            // Range-clamp every restored integer + cap the WoL free-text so an
            // untrusted blob can't drive a negative Duration (keepalive busy
            // loop), crash the pill-bar palette (negative colorIndex), or store
            // a control-char-laden WoL address.
            final colorIndex = _clampInt(map['colorIndex'], 0, 63);
            final keepAlive = _clampInt(map['keepAliveSeconds'], 0, 86400);
            final sortOrder = _clampInt(map['sortOrder'], 0, 1000000000);
            final wolMac = _capTextOpt(map['wolMacAddress'], 64);
            final wolBroadcast = _capTextOpt(map['wolBroadcastAddress'], 64);
            // Invalid/out-of-range WoL port → null rather than a bogus value.
            final wolPort = map['wolPort'] == null
                ? null
                : _validatePort(map['wolPort']);

            // The label is held to what the table takes (1 to 255): 512 were
            // let through, and none too, and the write threw and took the
            // whole restore with it (found in a security audit). A host
            // with no label is named by its address.
            final hostLabelGiven = _capText(_str(map['label']), 255);
            final hostLabel = hostLabelGiven.trim().isEmpty ? _capText(host, 255) : hostLabelGiven;
            if (hostLabel.isEmpty) continue;
            if (!fromThere('connections/$id', map['updatedAt'])) continue;
            final existing = await _connectionsDao.getById(id);
            if (existing != null) {
              // A host that is SFTP only comes back as SSH with the time of
              // change it went out with: a version from before that type read
              // it as SSH and sent it on (a person's change has a later time).
              // Taken as any other change, and noted for the screen of a host
              // that gives no terminal, which says to update that device.
              if (merge != null) {
                final there = _flexDateTime(map['updatedAt']);
                if (protocol == 'sftp') {
                  sftpOnlyAgain.add(id);
                } else if (existing.protocol == 'sftp' &&
                    protocol == 'ssh' &&
                    there != null &&
                    there.millisecondsSinceEpoch ~/ 1000 == existing.updatedAt.millisecondsSinceEpoch ~/ 1000) {
                  sftpOnlyTurnedBack.add(id);
                }
              }
              await _connectionsDao.updateConnection(ConnectionsCompanion(
                id: Value(id),
                label: Value(hostLabel),
                host: Value(host),
                port: Value(port),
                identityId: Value(_idOpt(map['identityId'])),
                groupId: Value(_idOpt(map['groupId'])),
                colorIndex: Value(colorIndex),
                colorValue: Value(_intOpt(map['colorValue'])),
                protocol: Value(protocol),
                zlibCompression: Value(_bool(map['zlibCompression'])),
                startupCommand: Value(startupCmd),
                snippetId: Value(_idOpt(map['snippetId'])),
                connectViaId: Value(_idOpt(map['connectViaId'])),
                keepAliveSeconds: Value(keepAlive),
                sortOrder: Value(sortOrder),
                wolMacAddress: Value(wolMac),
                wolBroadcastAddress: Value(wolBroadcast),
                wolPort: Value(wolPort),
                envVars: Value(envVars),
                forwardAgent: Value(_bool(map['forwardAgent'])),
                compatibilityMode: Value(_bool(map['compatibilityMode'])),
                sizeTier: Value(_validateTier(map['sizeTier'])),
                iconId: Value(_capTextOpt(map['iconId'], 64)),
                customIcon: Value(_capCustomIcon(map['customIcon'])),
                iconColor: Value(HostIconColor.fromOutside(map['iconColor'])),
                cloudSource: Value(_cloudSourceOpt(map['cloudSource'])),
                screenOptions: Value(_screenOptionsOpt(map['screenOptions'], protocol)),
                pinned: Value(_bool(map['pinned'])),
                monitored: Value(_bool(map['monitored'])),
                note: Value(note),
                pins: Value(_pinsJson(map['pins'])),
                // v14: the SFTP host default, bounded like every other field
                // from a peer (an absolute POSIX path, no control characters).
                lastRemotePath:
                    Value(sanitizeRemotePath(map['lastRemotePath'])),
                lastRemoteUser:
                    Value(sanitizeRemoteUser(map['lastRemoteUser'])),
                lastRemotePathAt: Value(_dateTimeOpt(map['lastRemotePathAt'])),
                // Preserve the record's real modification time so tombstone
                // "newest wins" arbitration stays valid across sync rounds
                // (a restore must NOT stamp now() - that would make every
                // synced row outrank an older delete forever).
                updatedAt:
                    Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
              ));
            } else {
              await _connectionsDao.insertConnection(ConnectionsCompanion(
                id: Value(id),
                label: Value(hostLabel),
                host: Value(host),
                port: Value(port),
                identityId: Value(_idOpt(map['identityId'])),
                groupId: Value(_idOpt(map['groupId'])),
                colorIndex: Value(colorIndex),
                colorValue: Value(_intOpt(map['colorValue'])),
                protocol: Value(protocol),
                zlibCompression: Value(_bool(map['zlibCompression'])),
                startupCommand: Value(startupCmd),
                snippetId: Value(_idOpt(map['snippetId'])),
                connectViaId: Value(_idOpt(map['connectViaId'])),
                keepAliveSeconds: Value(keepAlive),
                sortOrder: Value(sortOrder),
                wolMacAddress: Value(wolMac),
                wolBroadcastAddress: Value(wolBroadcast),
                wolPort: Value(wolPort),
                envVars: Value(envVars),
                forwardAgent: Value(_bool(map['forwardAgent'])),
                compatibilityMode: Value(_bool(map['compatibilityMode'])),
                sizeTier: Value(_validateTier(map['sizeTier'])),
                iconId: Value(_capTextOpt(map['iconId'], 64)),
                customIcon: Value(_capCustomIcon(map['customIcon'])),
                iconColor: Value(HostIconColor.fromOutside(map['iconColor'])),
                cloudSource: Value(_cloudSourceOpt(map['cloudSource'])),
                screenOptions: Value(_screenOptionsOpt(map['screenOptions'], protocol)),
                pinned: Value(_bool(map['pinned'])),
                monitored: Value(_bool(map['monitored'])),
                note: Value(note),
                pins: Value(_pinsJson(map['pins'])),
                // v14: the SFTP host default, bounded like every other field
                // from a peer (an absolute POSIX path, no control characters).
                lastRemotePath:
                    Value(sanitizeRemotePath(map['lastRemotePath'])),
                lastRemoteUser:
                    Value(sanitizeRemoteUser(map['lastRemoteUser'])),
                lastRemotePathAt: Value(_dateTimeOpt(map['lastRemotePathAt'])),
                lastConnected: _dateTimeOpt(map['lastConnected']) != null
                    ? Value(_dateTimeOpt(map['lastConnected'])!)
                    : const Value.absent(),
                createdAt: Value(_dateTime(map['createdAt'])),
                // Preserve the record's real modification time (see the update
                // path above) so tombstone arbitration stays valid.
                updatedAt:
                    Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
              ));
            }
            restored++;
          }
        }

        // Restore networks BEFORE host/port-forward overrides that reference
        // them. There are no DB foreign keys (the Networks feature uses
        // deliberate NON-FK references so a deleted network never cascades),
        // so ordering isn't required for integrity - but restoring parents
        // first keeps the merged state self-consistent within one pass.
        if (data['networks'] is List) {
          final networks = data['networks'] as List;
          for (final n in networks) {
            if (n is! Map) continue;
            final map = Map<String, dynamic>.from(n);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id

            // name is NOT NULL with a 1..64 length constraint - cap it and
            // fall back to a non-empty placeholder so a blank/oversized value
            // from an untrusted blob can't violate the column check.
            var name = _capText(_str(map['name']), 64);
            if (name.isEmpty) name = 'Network';

            // triggersJson must be a JSON array; anything malformed degrades to
            // the empty-triggers default rather than corrupting the detector.
            var triggersJson = _str(map['triggersJson']);
            if (triggersJson.length > 65536) {
              triggersJson = '[]';
            } else if (triggersJson.isEmpty) {
              triggersJson = '[]';
            } else {
              try {
                if (jsonDecode(triggersJson) is! List) triggersJson = '[]';
              } catch (_) {
                triggersJson = '[]';
              }
            }

            // Default network's sortOrder is 1<<30 (pinned last), so the clamp
            // ceiling must admit it.
            final networkCompanion = NetworksCompanion(
              id: Value(id),
              name: Value(name),
              colorIndex: Value(_clampInt(map['colorIndex'], 0, 63)),
              colorValue: Value(_intOpt(map['colorValue'])),
              iconCodePoint:
                  Value(_clampInt(map['iconCodePoint'], 0, 0x10FFFF)),
              iconFontFamily: Value(_capTextOpt(map['iconFontFamily'], 128)),
              iconFontPackage: Value(_capTextOpt(map['iconFontPackage'], 128)),
              triggersJson: Value(triggersJson),
              isFallback: Value(_bool(map['isFallback'])),
              bringUpVpn: Value(_capTextOpt(map['bringUpVpn'], 128)),
              sortOrder: Value(_clampInt(map['sortOrder'], 0, 1 << 30)),
              createdAt: Value(_dateTime(map['createdAt'])),
              updatedAt: Value(_flexDateTime(map['updatedAt'])),
            );
            if (!fromThere('networks/$id', map['updatedAt'])) continue;
            await _networksDao.upsertNetwork(networkCompanion);
            await keepTime('networks', 'id', 'networks/$id', id, map['updatedAt']);
            restored++;
          }
        }

        // Restore per-host network overrides. Upsert on the logical
        // (connectionId, networkId) pair - reuse the local row's id when the
        // pair already exists - so two devices that independently created an
        // override for the same pair converge onto ONE row instead of
        // duplicating it (a duplicate would trip the resolver's single-row
        // `getOverride`).
        if (data['host_network_overrides'] is List) {
          final overrides = data['host_network_overrides'] as List;
          for (final o in overrides) {
            if (o is! Map) continue;
            final map = Map<String, dynamic>.from(o);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id
            final connectionId = _str(map['connectionId']);
            final networkId = _str(map['networkId']);
            if (connectionId.isEmpty ||
                connectionId.length > 128 ||
                _hasControlChars(connectionId) ||
                networkId.isEmpty ||
                networkId.length > 128 ||
                _hasControlChars(networkId)) {
              continue;
            }

            // address is an optional hostname/IP override; reject control
            // chars / oversize (same rule as connection.host) → null=inherit.
            String? address = _strOpt(map['address']);
            if (address != null &&
                (_hasControlChars(address) || address.length > 253)) {
              address = null;
            }
            // Then strip the bidi/format + C1 controls a compromised blob
            // could use to homoglyph/RTL-spoof the address shown in the
            // connect / host-key-trust dialog - the same _renderUnsafe/_capText
            // treatment label & username already get. Display-only (the runtime
            // barrier is the host-key prompt, handled elsewhere): remove the
            // invisible chars rather than null the whole override, so the
            // functional target is unchanged. Length is already ≤253 here so
            // the cap is a no-op; null only if stripping empties it.
            if (address != null) {
              address = _capText(address, 253);
              if (address.isEmpty) address = null;
            }
            final port =
                map['port'] == null ? null : _validatePort(map['port']);

            // jumpChainJson is an optional JSON list of host ids; keep it only
            // when it parses as a list, else drop to null (inherit).
            String? jumpChainJson = _strOpt(map['jumpChainJson']);
            if (jumpChainJson != null) {
              if (jumpChainJson.length > 8192) {
                jumpChainJson = null;
              } else {
                try {
                  if (jsonDecode(jumpChainJson) is! List) jumpChainJson = null;
                } catch (_) {
                  jumpChainJson = null;
                }
              }
            }

            if (!fromThere('host_network_overrides/$connectionId|$networkId', map['updatedAt'])) continue;
            final existing = await _networksDao.getOverrideByPair(
                hostId: connectionId, networkId: networkId);
            await _networksDao.upsertOverride(HostNetworkOverridesCompanion(
              id: Value(existing?.id ?? id),
              connectionId: Value(connectionId),
              networkId: Value(networkId),
              address: Value(address),
              port: Value(port),
              username: Value(_capTextOpt(map['username'], 256)),
              identityId: Value(_capTextOpt(map['identityId'], 128)),
              jumpHostId: Value(_capTextOpt(map['jumpHostId'], 128)),
              jumpChainJson: Value(jumpChainJson),
              skipHost: Value(
                  map['skipHost'] == null ? null : _bool(map['skipHost'])),
              createdAt:
                  Value(existing?.createdAt ?? _dateTime(map['createdAt'])),
              // When it was changed, as the blob says (a restore is no change).
              updatedAt: Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
            ));
            restored++;
          }
        }

        // Host-key trust (known_hosts) IS restored as of blob v11, under a
        // strict policy so the vault can't silently seed trust:
        //  - Agreeing (same host+keytype+fingerprint): keep local, no-op.
        //  - Conflict (same host+keytype, DIFFERENT fingerprint): NEVER
        //    overwrite, NEVER trust both - keep local and report it, so it
        //    surfaces with the weight of a changed key.
        //  - New host+keytype: ADOPT only with real provenance (a recording
        //    device) and a firstSeen that predates this restore - so a bare or
        //    future-stamped injection isn't auto-trusted. Adopted rows are
        //    inserted NOT-locally-verified, so the first local connect surfaces
        //    the provenance ("recorded on DESKTOP-X on 14 Aug") before trust is
        //    ever silent.
        if (data['known_hosts'] is List) {
          final now = DateTime.now();
          for (final h in data['known_hosts'] as List) {
            final merged = await _mergedHostKey(h, now);
            if (merged == null) continue;
            final (:adopt, :conflict) = merged;
            if (conflict != null) {
              knownHostConflicts.add(conflict);
              continue;
            }
            await _knownHostsDao.upsertHost(adopt!);
            restored++;
          }
        }

        // Restore snippets
        if (data['snippets'] is List) {
          final snippets = data['snippets'] as List;
          for (final s in snippets) {
            if (s is! Map) continue;
            final map = Map<String, dynamic>.from(s);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id
            // Cap to the ACTUAL Drift column limits (label max 255, command
            // min 1 / max 4096) and skip a row that would violate the min-1
            // CHECK. Previously these were capped at 512 / 65536, so an empty
            // or over-long snippet in an untrusted blob threw InvalidDataException
            // which - uncaught in the loop - rolled back the WHOLE restore
            // transaction (a poisoned entry blocked ALL data from restoring).
            final lbl = _capText(_str(map['label']), 255);
            final cmd = _capText(_str(map['command']), 4096);
            if (lbl.isEmpty || cmd.isEmpty) continue; // min-length-1 CHECK
            if (!fromThere('snippets/$id', map['updatedAt'])) continue;
            final existing = await _snippetsDao.getById(id);
            final category = _capTextOpt(map['category'], 128);
            final snipSort = _clampInt(map['sortOrder'], 0, 1000000000);
            // v23 metadata (snippet + per-variable descriptions), blob v8.
            // Absent in <=v7 blobs (→ null). Capped like every other untrusted
            // string; parsed defensively at read time so an oversized or
            // malformed value can never crash the reader.
            final snipMetadata = _capTextOpt(map['metadata'], 8192);
            if (existing != null) {
              await _snippetsDao.updateSnippet(SnippetsCompanion(
                id: Value(id),
                label: Value(lbl),
                command: Value(cmd),
                category: Value(category),
                confirmBeforeRun: Value(_bool(map['confirmBeforeRun'])),
                isDefault: Value(_bool(map['isDefault'])),
                metadata: Value(snipMetadata),
                sortOrder: Value(snipSort),
                // Preserve real modification time for tombstone newest-wins.
                updatedAt:
                    Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
              ));
            } else {
              await _snippetsDao.insertSnippet(SnippetsCompanion(
                id: Value(id),
                label: Value(lbl),
                command: Value(cmd),
                category: Value(category),
                confirmBeforeRun: Value(_bool(map['confirmBeforeRun'])),
                isDefault: Value(_bool(map['isDefault'])),
                metadata: Value(snipMetadata),
                sortOrder: Value(snipSort),
                createdAt: Value(_dateTime(map['createdAt'])),
                // Preserve real modification time for tombstone newest-wins.
                updatedAt:
                    Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
              ));
            }
            restored++;
          }
        }

        // Restore snippet-category metadata (order / color / hidden). Tolerant
        // of a pre-v7 blob that lacks the key entirely (categories then fall
        // back to their defaults). Every field is clamped/validated the same
        // way the connection-group metadata is, so an untrusted blob can't put
        // a negative colorIndex into the palette lookup or an oversized name
        // into the PK. name is the primary key, so a control-char-stripped or
        // empty name is skipped rather than written.
        if (data['snippet_categories'] is List) {
          final cats = data['snippet_categories'] as List;
          for (final c in cats) {
            if (c is! Map) continue;
            final map = Map<String, dynamic>.from(c);
            final name = _capText(_str(map['name']), 128);
            if (name.isEmpty) continue; // PK must be non-empty
            // colorIndex is nullable by design (null = neutral default) and
            // absent in pre-v7 blobs - both decode to null. Clamp when present.
            final colorIndex = map['colorIndex'] == null
                ? null
                : _clampInt(map['colorIndex'], 0, 63);
            final sortOrder = _clampInt(map['sortOrder'], 0, 1000000000);
            if (!fromThere('snippet_categories/$name', map['updatedAt'])) continue;
            await _snippetCategoriesDao.upsert(SnippetCategoriesCompanion(
              name: Value(name),
              colorIndex: Value(colorIndex),
              colorValue: Value(_intOpt(map['colorValue'])),
              hidden: Value(_bool(map['hidden'])),
              sortOrder: Value(sortOrder),
              updatedAt: Value(_flexDateTime(map['updatedAt'])),
            ));
            await keepTime('snippet_categories', 'name', 'snippet_categories/$name', name, map['updatedAt']);
            restored++;
          }
        }

        // Restore port forward rules
        if (data['port_forward_rules'] is List) {
          final rules = data['port_forward_rules'] as List;
          final existingRules = {for (final r in await _portForwardRulesDao.getAll()) r.id: r};
          for (final r in rules) {
            if (r is! Map) continue;
            final map = Map<String, dynamic>.from(r);

            // Validate port forward fields from untrusted data.
            final pfType = _str(map['type']);
            const validPfTypes = {'local', 'remote', 'dynamic'};
            if (!validPfTypes.contains(pfType)) continue;
            final pfBindAddr = _str(map['bindAddress']);
            final pfRemoteHost = _str(map['remoteHost']);
            if (_hasControlChars(pfBindAddr) || pfBindAddr.length > 253) {
              continue;
            }
            if (_hasControlChars(pfRemoteHost) ||
                pfRemoteHost.length > 253) {
              continue;
            }
            final pfBindPort = _int(map['bindPort']);
            final pfRemotePort = _int(map['remotePort']);
            if (pfBindPort < 0 || pfBindPort > 65535) continue;
            if (pfRemotePort < 0 || pfRemotePort > 65535) continue;
            final pfId = _str(map['id']);
            if (pfId.isEmpty || pfId.length > 128) continue; // malformed id

            // Never open a synced forward automatically, and never expose it
            // beyond loopback, without the user approving it on this device.
            // A blob-supplied rule with autoStart=true + bindAddress=0.0.0.0
            // would silently open a LAN-reachable listener on every device the
            // moment sync lands (same policy as deep-link share import). Those
            // are this device's own to decide, and do not travel (3.0): a
            // forward this device already has keeps its own; one new here
            // starts by hand only, on loopback, and shared with nobody. (They
            // were set so for every forward, so each sync switched off what
            // had been switched on here.)
            final mine = existingRules[pfId];
            final keepMyBind = mine != null && !isLoopbackBind(mine.bindAddress);
            var safeBind = pfBindAddr;
            if (!isLoopbackBind(pfBindAddr)) {
              AppLogger.warning(
                  'Restore: forcing port-forward bindAddress "$pfBindAddr" '
                  'to loopback until approved on this device');
              safeBind = '127.0.0.1';
            }

            // A forward of no host, or of an id no host can have, is no rule.
            final pfConnection = _idOpt(map['connectionId']);
            if (pfConnection == null) continue;
            if (!fromThere('port_forward_rules/$pfId', map['updatedAt'])) continue;
            await _portForwardRulesDao.upsertRule(PortForwardRulesCompanion(
              id: Value(pfId),
              connectionId: Value(pfConnection),
              type: Value(pfType),
              bindAddress: keepMyBind ? const Value.absent() : Value(safeBind),
              bindPort: Value(pfBindPort),
              remoteHost: Value(pfRemoteHost),
              remotePort: Value(pfRemotePort),
              // Absent: kept where the forward is here, off where it is new.
              autoStart: const Value.absent(),
              reconnect: Value(map['reconnect'] is bool
                  ? map['reconnect'] as bool
                  : true),
              exitOnFailure: Value(map['exitOnFailure'] is bool
                  ? map['exitOnFailure'] as bool
                  : true),
              // SECURITY: like autoStart, a forward is shared with the LAN
              // (-g / GatewayPorts) only where it was on this device.
              gatewayPorts: const Value.absent(),
              sshFlags: Value(_capTextOpt(map['sshFlags'], 512)),
              label: Value(_capTextOpt(map['label'], 512)),
              createdAt: Value(_dateTime(map['createdAt'])),
              updatedAt: Value(_flexDateTime(map['updatedAt'])),
            ));
            await keepTime('port_forward_rules', 'id', 'port_forward_rules/$pfId', pfId, map['updatedAt']);
            restored++;
          }
        }

        // Restore trigger / highlight rules (blob v15). Every untrusted field is
        // validated/clamped; updatedAt is preserved for newest-wins.
        if (data['terminal_triggers'] is List) {
          final triggers = data['terminal_triggers'] as List;
          for (final t in triggers) {
            if (t is! Map) continue;
            final map = Map<String, dynamic>.from(t);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue;
            final name = _capTextOpt(map['name'], 255);
            final pattern = _capTextOpt(map['pattern'], 2048);
            if (name == null ||
                name.isEmpty ||
                pattern == null ||
                pattern.isEmpty) {
              continue;
            }
            final rawColor = map['highlightColor'];
            final int? highlightColor = rawColor is int
                ? rawColor
                : (rawColor is num ? rawColor.toInt() : null);
            final conn = _str(map['connectionId']);
            if (!fromThere('terminal_triggers/$id', map['updatedAt'])) continue;
            await _database.terminalTriggersDao.upsert(TerminalTriggersCompanion(
              id: Value(id),
              name: Value(name),
              pattern: Value(pattern),
              caseSensitive: Value(
                  map['caseSensitive'] is bool ? map['caseSensitive'] as bool : false),
              notify:
                  Value(map['notify'] is bool ? map['notify'] as bool : true),
              highlight: Value(
                  map['highlight'] is bool ? map['highlight'] as bool : false),
              highlightColor: Value(highlightColor),
              playSound: Value(
                  map['playSound'] is bool ? map['playSound'] as bool : false),
              connectionId: Value(conn.isEmpty ? null : conn),
              enabled:
                  Value(map['enabled'] is bool ? map['enabled'] as bool : true),
              sortOrder: Value(_int(map['sortOrder'])),
              createdAt: Value(_dateTime(map['createdAt'])),
              updatedAt: Value(_flexDateTime(map['updatedAt'])),
            ));
            await keepTime('terminal_triggers', 'id', 'terminal_triggers/$id', id, map['updatedAt']);
            restored++;
          }
        }

        // Restore command history (blob v16). Validate/clamp untrusted fields;
        // preserve updatedAt for newest-wins. Prune to the local cap once at the
        // end rather than per row.
        if (data['command_history'] is List) {
          final entries = data['command_history'] as List;
          var restoredHistory = false;
          for (final h in entries) {
            if (h is! Map) continue;
            final map = Map<String, dynamic>.from(h);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue;
            final command = _capTextOpt(map['command'], 4096);
            if (command == null || command.isEmpty) continue;
            final conn = _str(map['connectionId']);
            if (!fromThere('command_history/$id', map['updatedAt'])) continue;
            await _database.commandHistoryDao.upsert(CommandHistoryCompanion(
              id: Value(id),
              command: Value(command),
              connectionId: Value(conn.isEmpty ? null : conn),
              hostLabel: Value(_capTextOpt(map['hostLabel'], 255)),
              createdAt: Value(_dateTime(map['createdAt'])),
              updatedAt: Value(_flexDateTime(map['updatedAt'])),
            ));
            await keepTime('command_history', 'id', 'command_history/$id', id, map['updatedAt']);
            restored++;
            restoredHistory = true;
          }
          if (restoredHistory) {
            await _database.commandHistoryDao.pruneToCap();
          }
        }

        // Restore per-(rule, network) port-forward state overrides. Upsert on
        // the logical (ruleId, networkId) pair - reuse the local row's id when
        // the pair exists - because the table has a UNIQUE(ruleId, networkId)
        // constraint: a blind id-keyed insert of the same pair from another
        // device would violate it and abort the whole restore.
        if (data['port_forward_network_overrides'] is List) {
          final pfOverrides =
              data['port_forward_network_overrides'] as List;
          for (final o in pfOverrides) {
            if (o is! Map) continue;
            final map = Map<String, dynamic>.from(o);
            final id = _str(map['id']);
            if (id.isEmpty || id.length > 128) continue; // skip malformed id
            final ruleId = _str(map['ruleId']);
            final networkId = _str(map['networkId']);
            if (ruleId.isEmpty ||
                ruleId.length > 128 ||
                networkId.isEmpty ||
                networkId.length > 128) {
              continue;
            }
            // Whitelist the enum-as-string state; anything unknown falls back
            // to 'inherit' (the safe absence-of-opinion default).
            final stateRaw = _str(map['state']);
            const validStates = {'inherit', 'on', 'off'};
            final state =
                validStates.contains(stateRaw) ? stateRaw : 'inherit';

            if (!fromThere('port_forward_network_overrides/$ruleId|$networkId', map['updatedAt'])) continue;
            final existing = await _portForwardRulesDao
                .getNetworkOverrideByPair(ruleId, networkId);
            await _portForwardRulesDao.upsertNetworkOverride(
              PortForwardNetworkOverridesCompanion(
                id: Value(existing?.id ?? id),
                ruleId: Value(ruleId),
                networkId: Value(networkId),
                state: Value(state),
                createdAt:
                    Value(existing?.createdAt ?? _dateTime(map['createdAt'])),
                // When it was changed, as the blob says (a restore is no change).
                updatedAt: Value(_flexDateTime(map['updatedAt']) ?? DateTime.now()),
              ),
            );
            restored++;
          }
        }

        // What a merge was told to hear of goes in with what it wrote: stopped from
        // here on, it is still known which keys came and have their secrets to come.
        await merge?.onTaken?.call(taken);

        // Newest-wins delete-propagation: remove local records a tombstone
        // outranks. Done LAST so a record the blob just (re)stored with an
        // updatedAt newer than the tombstone survives (edit-beats-delete),
        // while a stale or absent one is removed (delete-beats-edit).
        await _applyTombstoneDeletions(tombstones);

        // What a backup brought back that was deleted here: changed now, and
        // after its deletion (made in the same second, a tie the deletion
        // wins), so the deletion does not remove it again ([asBackup]).
        if (broughtBack.isNotEmpty) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          for (final (table, key, id, deletedAt) in broughtBack) {
            final after = deletedAt.millisecondsSinceEpoch ~/ 1000 + 1;
            await _database.customStatement(
                'UPDATE $table SET updated_at = ? WHERE $key = ?', [now > after ? now : after, id]);
          }
        }
      });

      // Connection tags (blob v13): replace each surviving connection's tag set
      // with the blob's. Applied AFTER the transaction (like secrets) and ONLY
      // for connections that exist locally post-restore, so a tombstoned host's
      // tags are never resurrected and no orphan tag row is written. Values are
      // re-normalized (bounded case/length) since the blob is untrusted input.
      if (data['connection_tags'] is Map) {
        final blobTags =
            Map<String, dynamic>.from(data['connection_tags'] as Map);
        final localConnIds =
            (await _connectionsDao.getAll()).map((c) => c.id).toSet();
        for (final entry in blobTags.entries) {
          final connId = entry.key;
          if (!localConnIds.contains(connId)) continue;
          // A host kept as it is here keeps its tags, which are part of it.
          if (merge != null && !taken.contains('connections/$connId')) continue;
          final rawTags = entry.value;
          if (rawTags is! List) continue;
          final desired = <String>{};
          for (final t in rawTags) {
            final norm = ConnectionTagsDao.normalize(t.toString());
            if (norm != null) desired.add(norm);
          }
          // Skip the write when the local set already matches, to avoid needless
          // churn (and a redundant tableUpdates push nudge) on an unchanged pull.
          final current =
              (await _connectionTagsDao.getTagsForConnection(connId)).toSet();
          if (current.length == desired.length &&
              current.containsAll(desired)) {
            continue;
          }
          await _connectionTagsDao.setTagsForConnection(connId, desired);
        }
      }

      // A host's other accounts (blob v22). For each host the blob holds that
      // is here after the restore, the blob's list is taken, as the host's own
      // row was (a host the blob holds without any has none, so taking the
      // last one off travels too); a host only this device has keeps its own.
      // Untrusted: only identities that are here, ids bounded, and so is a
      // list; never the host's default (the DAO leaves it out).
      if (data['host_accounts'] is Map && data['connections'] is List) {
        final blobAccounts = Map<String, dynamic>.from(data['host_accounts'] as Map);
        final localHosts = {for (final c in await _connectionsDao.getAll()) c.id};
        final localIdentities = {for (final i in await _identitiesDao.getAll()) i.id};
        for (final c in data['connections'] as List) {
          if (c is! Map) continue;
          final hostId = _str(c['id']);
          if (!localHosts.contains(hostId)) continue;
          if (merge != null && !taken.contains('connections/$hostId')) continue;
          final raw = blobAccounts[hostId];
          await _database.hostAccountsDao.setOtherAccounts(hostId, [
            if (raw is List)
              for (final id in raw.take(64))
                if (id is String && id.length <= 128 && localIdentities.contains(id)) id,
          ]);
        }
      }

      // Restore identity secrets AFTER the transaction succeeds,
      // so that if the transaction rolls back, secrets aren't orphaned.
      //
      // Only write secrets whose identity row actually exists locally after
      // this restore - a blob could otherwise write unbounded attacker-chosen
      // values into secure storage under arbitrary, never-referenced keys
      // (storage bloat / a landmine the app might later read by id). Cap each
      // value (PEM keys are < 64 KB, passwords/passphrases < 4 KB) so a hostile
      // blob can't stuff megabytes per entry either.
      const maxPasswordLen = 4096;
      const maxPrivateKeyLen = 64 * 1024;
      // A certificate is kept as base64: an OpenSSH one is a few KB.
      const maxCertificateLen = 64 * 1024;
      final localIdentityIds =
          (await _identitiesDao.getAll()).map((i) => i.id).toSet();
      int secretsRestored = 0;
      int secretsFailed = 0;
      int secretsSkipped = 0;
      if (data['secrets'] is Map) {
        final secrets = Map<String, dynamic>.from(data['secrets'] as Map);
        for (final entry in secrets.entries) {
          final identityId = entry.key;
          // Reject orphan / malformed identity ids up front.
          if (identityId.isEmpty ||
              identityId.length > 128 ||
              _hasControlChars(identityId) ||
              !localIdentityIds.contains(identityId)) {
            secretsSkipped++;
            continue;
          }
          // A key kept as it is here keeps its secrets, which are part of it.
          if (merge != null && !taken.contains('identities/$identityId')) continue;
          try {
            // Cast inside the try so one malformed secrets entry is skipped,
            // not fatal (it also runs after the DB transaction committed).
            if (entry.value is! Map) {
              secretsFailed++;
              continue;
            }
            final creds = Map<String, dynamic>.from(entry.value as Map);
            final password = creds['password']?.toString();
            if (password != null) {
              if (password.length > maxPasswordLen) {
                secretsSkipped++;
              } else {
                await _identitySecrets.write(identityId, IdentitySecret.password, password);
                secretsRestored++;
              }
            }
            final privateKey = creds['privateKey']?.toString();
            if (privateKey != null) {
              if (privateKey.length > maxPrivateKeyLen) {
                secretsSkipped++;
              } else {
                await _identitySecrets.write(identityId, IdentitySecret.privateKey, privateKey);
                secretsRestored++;
              }
            }
            final passphrase = creds['passphrase']?.toString();
            if (passphrase != null) {
              if (passphrase.length > maxPasswordLen) {
                secretsSkipped++;
              } else {
                await _identitySecrets.write(identityId, IdentitySecret.passphrase, passphrase);
                secretsRestored++;
              }
            }
            final certificate = creds['certificate']?.toString();
            if (certificate != null) {
              if (certificate.length > maxCertificateLen || !_isBase64(certificate)) {
                secretsSkipped++;
              } else {
                await _identitySecrets.write(identityId, IdentitySecret.certificate, certificate);
                secretsRestored++;
              }
            }
          } catch (e) {
            secretsFailed++;
            AppLogger.error(
              'Failed to write identity secret for $identityId to secure storage', e);
          }
        }
      }
      // A key only another device changed since this one last synced is taken
      // as that device has it, its secrets too: a secret it no longer has (a
      // saved password moved into a password manager, or removed) is removed
      // here. (Only what the blob held was written, so the removal never
      // travelled, and this device's next push sent the old password back to
      // the device it was taken off.) Only from a blob of version 22 or later,
      // whose writer sent every secret a key held (an older one sent no
      // passphrase or certificate); and never where this device changed the
      // key too, or the store went back: what is here is kept there.
      if (blobSchema >= 22) {
        final blobSecrets = data['secrets'] is Map ? data['secrets'] as Map : const {};
        for (final item in changedThere) {
          if (!item.startsWith('identities/')) continue;
          final identityId = item.substring('identities/'.length);
          if (!localIdentityIds.contains(identityId)) continue;
          final creds = blobSecrets[identityId];
          if (creds != null && creds is! Map) continue;
          for (final secret in IdentitySecret.values) {
            if (creds is Map && creds[secret.name] != null) continue;
            try {
              if (await _identitySecrets.read(identityId, secret) == null) continue;
              await _identitySecrets.write(identityId, secret, null);
            } catch (e) {
              AppLogger.warning('Sync: a secret another device took off a key is still here (${errorKind(e)})');
            }
          }
        }
      }
      if (secretsFailed > 0 || secretsSkipped > 0) {
        AppLogger.warning(
          'Restored $secretsRestored secrets '
          '($secretsSkipped skipped, $secretsFailed failed to save). '
          'Credentials may need to be re-entered on this device.');
      }

      // Apply synced app/terminal settings AFTER the transaction commits (they
      // live in SharedPreferences, not the DB, so they're outside the txn).
      // SettingsService allowlists, type-checks and bounds-clamps every value,
      // so a hostile blob can't write arbitrary prefs. Best-effort: a failure
      // here never fails the record restore.
      if (data['settings'] is Map) {
        try {
          final settings = Map<String, dynamic>.from(data['settings'] as Map);
          // A setting changed here and not there is kept, as an item is.
          if (merge != null) settings.removeWhere((key, _) => !fromThere('settings/$key', null));
          await _settingsService.importSyncedSettings(settings);
        } catch (e) {
          AppLogger.warning('Failed to apply synced settings on restore: $e');
        }
      }

      // Account keys another device made (v18). Stored as unverified until
      // they match what the server published (AccountKeyService). Best-effort:
      // a failure never fails the record restore.
      try {
        await AccountKeyStore(_secureStorage, tree: () => _database)
            .importFromSync(data['account_keys'], account: _accountUid());
      } catch (e) {
        AppLogger.warning('Failed to store synced account keys: $e');
      }

      // Sweep secure-storage secrets whose identity no longer exists (orphans
      // left by an earlier device or a previous unbounded restore). Bounded and
      // best-effort - a failure here never fails the restore.
      await _sweepOrphanIdentitySecrets();

      // A key deleted elsewhere is named no more by what this device kept of
      // its hosts (a host kept as it is here, a network's settings for it):
      // they signed in with nothing. Best-effort, as the sweep.
      try {
        await _database.hostAccountsDao.forgetMissingIdentities();
      } catch (e) {
        AppLogger.warning('Keys no longer here still named: $e');
      }

      // What came back of hosts that are SFTP only: this device's own note.
      try {
        for (final id in sftpOnlyTurnedBack) {
          await _settingsService.noteSftpOnlyTurnedBack(id);
        }
        for (final id in sftpOnlyAgain) {
          await _settingsService.forgetSftpOnlyTurnedBack(id);
        }
      } catch (e) {
        AppLogger.warning('Could not note a host turned back into SSH: $e');
      }

      // The store's count, as far as this device has seen it. (A backup holds
      // none: withoutStoreCount.)
      final count = storeCountOf(data);
      if (count != null) await noteStoreCount(count);

      AppLogger.info('Sync restore complete: $restored records, $keptHere kept as they are here');
      return SyncRestoreResult(
        success: true,
        recordsRestored: restored,
        knownHostConflicts: knownHostConflicts,
        keptHere: keptHere,
        taken: taken,
      );
    } catch (e) {
      if (unread != null && identical(e, unread)) rethrow;
      AppLogger.error('Sync restore failed', e);
      return SyncRestoreResult(
        success: false,
        recordsRestored: restored,
        error: e.toString(),
      );
    }
  }

  /// Whether [s] is base64 as a certificate is kept: one that is not could
  /// only be read as an error when it is used.
  static bool _isBase64(String s) {
    try {
      base64.decode(s);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Delete `identity_password_*` / `identity_key_*` / `identity_passphrase_*`
  /// / `identity_cert_*` secure-storage entries whose identity is not in the
  /// database. Best-effort: swallows storage errors so a sweep failure never
  /// fails a restore.
  ///
  /// The entries' names are read first and the identities after, here and not
  /// earlier in the restore: every writer commits an identity before it writes its
  /// secrets, so the identity of any secret seen is there by the second read. With
  /// the identities read first, a key that came in meanwhile (guest data brought in
  /// while a pull ran) was taken for a leftover, and its secret deleted for good.
  ///
  /// Names only, never what they hold (3.3.2): on a Mac each read of a value may
  /// bring up macOS's question about the keychain, and this ran after every pull
  /// that changed something, reading every secret of the profile each time.
  static final _identitySecretKey =
      RegExp(r'^identity_(?:password|key|passphrase|cert)_(.+)$');

  Future<void> _sweepOrphanIdentitySecrets() async {
    try {
      final names = await keychainStoreNames(_secureStorage);
      final liveIds = (await _identitiesDao.getAll()).map((i) => i.id).toSet();
      for (final key in names) {
        final m = _identitySecretKey.firstMatch(key);
        if (m == null) continue;
        final id = m.group(1)!;
        if (!liveIds.contains(id)) {
          try {
            await _secureStorage.delete(key: key);
          } catch (_) {/* best-effort per-key */}
        }
      }
    } catch (e) {
      AppLogger.warning('Orphan identity-secret sweep skipped: $e');
    }
  }
}

class SyncRestoreResult {
  final bool success;
  final int recordsRestored;
  final String? error;

  /// "host:port" of any host key where a synced fingerprint DIFFERED from the
  /// one already trusted locally. Never merged (kept local, both never trusted);
  /// surfaced to the user with the weight of a changed key.
  final List<String> knownHostConflicts;

  /// How many items a pull kept as they are on this device, changed here
  /// since the last sync and not there, or later here: the push that
  /// follows sends them.
  final int keptHere;

  /// With a merge, the items written from the blob ([SyncDataService.itemHashes]
  /// names them): one that is not here was kept as it is, or was the same.
  final Set<String> taken;

  const SyncRestoreResult({
    required this.success,
    required this.recordsRestored,
    this.error,
    this.knownHostConflicts = const [],
    this.keptHere = 0,
    this.taken = const {},
  });
}

/// What a pull does with an item this device has as well (3.0).
enum SyncTake {
  /// The other devices' copy is written here.
  incoming,

  /// This device's copy is kept: the next push sends it.
  local,

  /// The two are the same: nothing is written.
  same,
}

/// What a pull merges with (3.0; whether "on merge,
/// timestamps are compared and newest wins" holds): each item as
/// this device last synced it ([base], from [SyncDataService.itemHashes] of
/// what it last pushed or took whole), under the key ([key], the DEK) the
/// hashes are made with. With no base yet, an item changed on both sides is
/// decided by when it was changed, where that can be told.
/// What a restore of a backup would do, shown before anything is written
/// ([SyncDataService.previewRestore]; found in the client's
/// security review: a restore wrote it all at once, unseen, a host that runs
/// a command as it connects or forwards the agent among it).
class RestorePreview {
  const RestorePreview({
    required this.hosts,
    required this.keys,
    required this.snippets,
    required this.other,
    required this.replaces,
    required this.acting,
    this.weakens = const [],
    this.hostKeys = const [],
  });

  final int hosts;
  final int keys;
  final int snippets;
  final int other;

  /// Items here that the backup's copy writes over with another content.
  final int replaces;

  /// The hosts the backup brings, new or changed, that do something by
  /// themselves: each by its label, with what it does.
  final List<(String, Set<HostActsAlone>)> acting;

  /// The settings the backup would change to something less safe than they are
  /// here, by their keys ([SettingsService.settingsThatWeaken]). Each stays as it
  /// is unless the person ticks it ([RestoreChoice]).
  final List<String> weakens;

  /// The hosts whose keys the backup would trust that this device has not
  /// confirmed itself, each with its route. They come only when the person
  /// ticks it ([RestoreChoice.takeHostKeys]); otherwise each is asked about at
  /// its first connect, as on a new device.
  final List<RestoreHostKey> hostKeys;
}

/// A host whose key a backup would trust ([RestorePreview.hostKeys]): the host
/// as "host:port", and the jump host it is for connections through (as the
/// route is kept: "bastion.example.com:22", or 'via:' and the jump host's id),
/// null for direct connections.
class RestoreHostKey {
  const RestoreHostKey(this.host, {this.via});

  final String host;
  final String? via;

  @override
  bool operator ==(Object other) => other is RestoreHostKey && other.host == host && other.via == via;

  @override
  int get hashCode => Object.hash(host, via);

  @override
  String toString() => via == null ? host : '$host via $via';
}

/// What the person answered to a [RestorePreview] that restores.
class RestoreChoice {
  const RestoreChoice({this.takeSettings = const {}, this.takeHostKeys = false});

  /// Those of [RestorePreview.weakens] the person ticked: the rest stay as they
  /// are here.
  final Set<String> takeSettings;

  /// Whether the person ticked to trust [RestorePreview.hostKeys] as the backup
  /// does.
  final bool takeHostKeys;
}

/// What a host does by itself, as a restore's preview says it.
enum HostActsAlone {
  /// Runs a command once connected.
  runsCommand,

  /// Runs a snippet once connected.
  runsSnippet,

  /// Types variables into its shell once connected, which what it then runs
  /// goes by.
  setsVariables,

  /// Opens a shell on this computer, and runs what it holds there.
  runsHere,

  /// Starts a port forward once connected.
  startsForward,

  /// Hands the host the person's SSH agent.
  forwardsAgent,

  /// Is connected to in the background, by the monitor.
  monitored,

  /// Also offers this host the old algorithms it may ask for.
  compatibilityMode,
}

class SyncMergeBase {
  const SyncMergeBase({required this.key, this.base, this.storeWentBack = false})
      : lastChanged = false,
        owed = const {},
        onTaken = null;

  /// No base to merge with, as when joining sync ([SyncDataService.restoreAll]
  /// without a merge): an item changed here later than the incoming copy, by
  /// times that can be trusted, is kept; otherwise the incoming copy is taken.
  /// Any key: only whether two copies are the same is asked.
  static const noBase = SyncMergeBase(key: [0x6a, 0x6f, 0x69, 0x6e]);

  /// Copies with no history in common, as guest data and an account's are: of two
  /// that differ the one changed last stands, and what is here wherever that cannot
  /// be told ([owed] apart). [onTaken] is told what was written, in the restore's
  /// transaction, before any secret is.
  const SyncMergeBase.lastChanged({required this.key, this.owed = const {}, this.onTaken})
      : base = null,
        storeWentBack = false,
        lastChanged = true;

  final List<int> key;
  final Map<String, String>? base;

  /// Whether this is [SyncMergeBase.lastChanged].
  final bool lastChanged;

  /// Items written by a restore that stopped before their secrets were: they are
  /// written again, unless changed since.
  final Set<String> owed;

  final Future<void> Function(Set<String> taken)? onTaken;

  /// Whether the store is not where this device left it (behind it, at its
  /// count with another content, or giving a blob below the highest count seen
  /// here), so that what it holds may be older than what this device last synced.
  final bool storeWentBack;
}

/// The ambiguous local-only set surfaced by
/// [SyncDataService.assessStaleReconcile]: for each entity type, the ids of
/// local rows the cloud neither has nor remembers deleting. On a stale device
/// these are the rows a blind union would resurrect on the next push.
class StaleReconcileReport {
  /// entityType (blob key, e.g. `connections`) -> local row ids not in cloud.
  final Map<String, List<String>> localOnlyIds;

  const StaleReconcileReport(this.localOnlyIds);

  int countFor(String type) => localOnlyIds[type]?.length ?? 0;

  int get total =>
      localOnlyIds.values.fold(0, (sum, ids) => sum + ids.length);

  bool get hasLocalOnly => total > 0;
}
