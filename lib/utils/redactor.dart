import 'dart:convert';

import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/utils/ssh_protocol_names.dart';

export 'package:zestssh/models/redactable.dart' show RedactKind;

/// How aggressively recording mode disguises names (spec §4).
enum RedactLevel {
  /// The 3a rule: first two, three zeros, last two. Keeps the shape of your
  /// names so a bug report can still say "the third Proxmox down", at the
  /// cost that someone who knows the setup may recognise it.
  layout,

  /// Unrelated words (`willow`, `basalt`, `cinder`). For anything public.
  strict,
}

/// Deterministic redaction for Recording (presenter) mode.
///
/// When recording mode is on, every identifying value the app's own chrome
/// renders (host, group, workspace and account names, addresses, usernames,
/// key names and comments, fingerprints, free text that embeds any of those)
/// is replaced with a stable, obviously-synthetic stand-in, so a screenshot or
/// a screen share leaks nothing real.
///
/// Screens never call these rules directly: a model exposes a [Redactable]
/// and the screen renders its `display`, which routes through [apply]. The
/// static helpers below are the rule primitives, kept for the handful of
/// legacy call sites and for tests; they ALWAYS mask.
///
/// Every mapping is deterministic (an FNV-1a hash of the real value, keyed
/// with a per-install [salt]), so the same real value yields the same fake
/// everywhere: a host shows the same masked name in the sidebar, its card,
/// its tab and its dialogs. The salt keeps a viewer from confirming a guess
/// by hashing a candidate value themselves.
///
/// Scope: this masks the app's OWN chrome only. It cannot rewrite live
/// terminal output, which is whatever the remote machine prints.
class Redactor {
  Redactor._();

  static final Redactor instance = Redactor._();

  /// Mirrors the recording-mode setting. Set by the settings layer on toggle
  /// and at startup; [apply] is a pass-through while this is false.
  bool get enabled => _enabled;
  set enabled(bool on) {
    if (_enabled == on) return;
    _enabled = on;
    onChanged?.call();
  }

  bool _enabled = false;

  RedactLevel get level => _level;
  set level(RedactLevel to) {
    if (_level == to) return;
    _level = to;
    onChanged?.call();
  }

  RedactLevel _level = RedactLevel.layout;

  /// Told of each change of [enabled] or [level]: the main window keeps its
  /// editor windows of their own in step with it (3.4.1).
  void Function()? onChanged;

  /// Per-install secret mixed into every hashed stand-in. Seeded from
  /// preferences at bootstrap (generated once, never synced); empty in tests,
  /// where the fakes then depend on the value alone.
  String salt = '';

  /// Names shorter than this carry nothing worth keeping: `lb-02` masked by the
  /// 3a rule is `lb00002`, which is the name with zeros in it (spec 3b).
  static const int kShortNameFloor = 7;

  // ── The visible set (spec 3c) ─────────────────────────────────────
  //
  // Fixed-width masks collide (`app-server-01` and `app-router-01` are both
  // `ap00001`). The fleet's names are registered here so collisions can be
  // resolved with a counter, assigned in sorted order, so the mapping is the
  // same on every screen within a session.
  final Set<String> _names = <String>{};
  Map<String, String>? _layoutTable;
  Map<String, String>? _strictTable;

  // Registered host ADDRESSES, so a bare `db-primary.local` or `192.168.10.21`
  // embedded in free text is masked by the address rule even when the
  // generic scan cannot recognise it as one (a single-dot DNS name).
  final Set<String> _addresses = <String>{};

  // Every name mask this session handed out. A value composed from masks (a
  // tab label "db000ry, ba000on") must come back unchanged from a second
  // pass, and only something this class produced counts: a real account
  // called `willow` or a real host called `host-42` is still masked.
  final Set<String> _produced = <String>{};

  /// Register every name that may render (host labels, group and workspace
  /// names). Idempotent; a genuinely new name invalidates the collision table.
  void registerNames(Iterable<String> names) {
    var changed = false;
    for (final n in names) {
      final c = n.trim();
      if (c.isNotEmpty && _names.add(c)) changed = true;
    }
    if (changed) {
      _layoutTable = null;
      _strictTable = null;
    }
  }

  /// Register every host address that may render (the address rule applies
  /// to them wherever they appear, including inside free text).
  void registerAddresses(Iterable<String> addresses) {
    for (final a in addresses) {
      final c = a.trim();
      if (c.isNotEmpty) _addresses.add(c);
    }
  }

  /// How this masks now, for an editor window of its own (3.4.1): its own
  /// engine, with a Redactor of its own that masks as the main window's only
  /// once it has the same mode, level, salt and registered names
  /// ([fromWindow]). It crosses the app's in-process window channel only,
  /// never a window's command line (the salt is no one else's).
  Map<String, Object?> toWindow() => {
        'on': enabled,
        'level': level.name,
        'salt': salt,
        'names': _names.toList(),
        'addresses': _addresses.toList(),
      };

  /// Masks as [toWindow] said the main window does. A state that cannot be
  /// read leaves recording mode as it was.
  void fromWindow(Object? state) {
    if (state is! Map) return;
    final on = state['on'];
    if (on is! bool) return;
    final names = state['names'];
    final addresses = state['addresses'];
    if (state['salt'] is String) salt = state['salt'] as String;
    level = RedactLevel.values.asNameMap()[state['level']] ?? level;
    if (names is List) registerNames(names.whereType<String>());
    if (addresses is List) registerAddresses(addresses.whereType<String>());
    enabled = on;
  }

  /// Forget the registered sets and the produced masks (tests, sign-out).
  void clearNames() {
    _names.clear();
    _addresses.clear();
    _produced.clear();
    _layoutTable = null;
    _strictTable = null;
  }

  // ── Dispatch ──────────────────────────────────────────────────────

  /// The display form of [raw] for [kind]: the real value while recording
  /// mode is off, the masked value while it is on.
  String apply(String raw, RedactKind kind) {
    if (!enabled) return raw;
    switch (kind) {
      case RedactKind.host:
      case RedactKind.group:
      case RedactKind.workspace:
      case RedactKind.account:
      case RedactKind.network:
        return name(raw);
      case RedactKind.address:
        return address(raw);
      case RedactKind.username:
        return username(raw);
      case RedactKind.keyName:
        return keyName(raw);
      case RedactKind.keyComment:
        // Usually `user@host`, which the free-text scan rewrites. A bare word
        // (`yubikey`) would pass the scan untouched, and it still names a
        // key, so it falls back to the key-name token.
        final scanned = line(raw);
        return scanned == raw ? keyName(raw) : scanned;
      case RedactKind.freeText:
        return line(raw);
      case RedactKind.path:
        return path(raw);
      case RedactKind.command:
        return command(raw);
      case RedactKind.fingerprint:
        return fingerprint(raw);
      case RedactKind.password:
        return passwordMask;
    }
  }

  /// What a secret value renders as. Never the real length.
  static const String passwordMask = '••••••••';

  // ── Hash ──────────────────────────────────────────────────────────

  /// Stable non-negative 32-bit hash (FNV-1a over the salt and the value).
  /// Deliberately NOT [String.hashCode], which is randomized per run and
  /// would make the fakes change every launch.
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in (instance.salt + s).codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  static int _nn(String s) => (_hash(s) % 90) + 10; // 10..99

  // ── Names (spec 3a, 3b, 3c, 4) ────────────────────────────────────

  /// A host / group / workspace / account name to its masked form at the
  /// current [level], with collision counters from the registered set.
  static String name(String raw) => instance._name(raw);

  static final RegExp _lineBreaks = RegExp(r'[\r\n]+');

  String _name(String raw) {
    final clean = raw.replaceAll(_lineBreaks, ' ').trim();
    if (clean.isEmpty) return raw;
    // A value masked upstream (a tab label composed from masked pieces) must
    // come through unchanged, or two screens would disagree. Only a value
    // this class produced counts as a mask: a real host that happens to be
    // called `willow` is still masked.
    if (!_names.contains(clean) && _isProduced(clean)) return clean;
    // An address, a `user@host` or a dotted name that arrived as a NAME (a
    // label-less host shows its address, a Quick Connect session is labelled
    // `user@host`) keeps its shape through the name rule (`192.168.10.21` would
    // become `1000024`): route it to the rules made for it.
    if (_addressLike(clean)) {
      return _userAtHost.hasMatch(clean) ? _line(clean) : address(clean);
    }
    final table = level == RedactLevel.strict ? _strict() : _layout();
    final hit = table[clean];
    if (hit != null) return _remember(hit);
    // Not registered (a value that appeared without going through the fleet
    // providers): mask it on its own, with no collision knowledge.
    return _remember(level == RedactLevel.strict
        ? _strictWord(clean, const <String>{})
        : _maskName(clean));
  }

  String _remember(String mask) {
    _produced.add(mask);
    return mask;
  }

  /// The 3a rule: first two, three zeros, last two. Fixed width regardless of
  /// input length, so the original length is never inferable.
  static String maskName(String n) => instance._remember(instance._maskName(n));

  String _maskName(String n) {
    final clean = n.trim();
    if (clean.length < kShortNameFloor) return _shortFallback(clean);
    final masked =
        '${clean.substring(0, 2)}000${clean.substring(clean.length - 2)}';
    // A name that already has the mask's shape (`ab000cd`) is its own mask,
    // which would show it unchanged: give it the short form instead.
    return masked == clean ? _shortFallback(clean) : masked;
  }

  String _shortFallback(String clean) => 'host-${_nn(clean)}';

  static final RegExp _counter = RegExp(r'^\d+$');
  static final RegExp _compositeSplit = RegExp(r'[,+\s]+');

  /// True for a mask this session produced, or a composite of them and
  /// counts (`db000ry, ba000on`, `db000ry +2`).
  bool _isProduced(String s) {
    if (_produced.contains(s)) return true;
    final parts =
        s.split(_compositeSplit).where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return false;
    return parts.every((p) => _produced.contains(p) || _counter.hasMatch(p));
  }

  // Shapes that are addresses rather than names.
  static final RegExp _userAtHost =
      RegExp(r'^[A-Za-z0-9._+-]+(?:@[A-Za-z0-9._+-]+)*@[^\s@]+$');
  static final RegExp _ipv4Port =
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?$');
  static final RegExp _dottedHost = RegExp(
      r'^(?=.*[A-Za-z])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+(?::\d{1,5})?$');

  static bool _addressLike(String s) {
    if (_userAtHost.hasMatch(s)) return true;
    if (_ipv4Port.hasMatch(s)) return true;
    if (_looksIpv6(s.startsWith('[') ? s.substring(1).split(']').first : s)) {
      return true;
    }
    return _dottedHost.hasMatch(s);
  }

  Map<String, String> _layout() {
    final cached = _layoutTable;
    if (cached != null) return cached;
    final sorted = _names.toList()..sort();
    final byMask = <String, List<String>>{};
    for (final n in sorted) {
      byMask.putIfAbsent(_maskName(n), () => <String>[]).add(n);
    }
    final table = <String, String>{};
    for (final entry in byMask.entries) {
      final members = entry.value; // already in sorted order
      if (members.length == 1) {
        table[members.single] = entry.key;
      } else {
        // Spec 3c: a counter only where needed, assigned in sorted order so
        // "the second app server" means the same row on every screen.
        for (var i = 0; i < members.length; i++) {
          table[members[i]] = '${entry.key}-${i + 1}';
        }
      }
    }
    return _layoutTable = table;
  }

  // Spec 4, Strict: unrelated words. Chosen so that, wherever the list
  // allows, the word shares no letters with the original.
  static const List<String> strictWords = [
    'willow', 'basalt', 'cinder', 'ember', 'quartz', 'juniper', 'cobalt',
    'marble', 'saffron', 'ivory', 'harbor', 'meadow', 'orchid', 'pebble',
    'tundra', 'velvet', 'zephyr', 'amber', 'birch', 'canyon', 'dune', 'fjord',
    'glacier', 'hollow', 'indigo', 'jasper', 'kelp', 'lagoon', 'mesa',
    'nectar', 'onyx', 'prairie', 'quill', 'ridge', 'sable', 'thistle',
    'umber', 'vortex', 'walnut', 'yarrow', 'zinc', 'aspen', 'brook', 'cedar',
    'delta', 'ebony', 'fern', 'grove', 'heron', 'iris', 'jade', 'kiln',
    'lark', 'moss', 'nook', 'opal', 'plume', 'reed', 'slate', 'tulip', 'vale',
    'wren', 'acorn', 'bramble', 'cliff', 'drift', 'eddy', 'flint', 'gale',
    'hazel', 'inlet', 'knoll', 'lumen', 'mirth', 'nimbus', 'oriel', 'pine',
    'rill', 'sedge', 'thorn', 'urn', 'vane', 'wisp', 'ash', 'beryl', 'coral',
    'dusk', 'elm', 'frost', 'gust', 'haze', 'ivy', 'loam', 'mist', 'oak',
    'peat', 'rye', 'silt', 'tarn',
  ];

  Map<String, String> _strict() {
    final cached = _strictTable;
    if (cached != null) return cached;
    final sorted = _names.toList()..sort();
    final taken = <String>{};
    final table = <String, String>{};
    for (final n in sorted) {
      final w = _strictWord(n, taken);
      taken.add(w);
      table[n] = w;
    }
    return _strictTable = table;
  }

  static Set<int> _letters(String s) => {
        for (final u in s.toLowerCase().codeUnits)
          if (u >= 0x61 && u <= 0x7a) u
      };

  String _strictWord(String clean, Set<String> taken) {
    final start = _hash(clean) % strictWords.length;
    final own = _letters(clean);
    String? fallback;
    for (var i = 0; i < strictWords.length; i++) {
      final w = strictWords[(start + i) % strictWords.length];
      if (taken.contains(w)) continue;
      if (_letters(w).intersection(own).isEmpty) return w;
      fallback ??= w;
    }
    // Every word taken or every word shares a letter: still a list word, and
    // still distinct from the original, with a counter to stay unique.
    final w = fallback ?? strictWords[start];
    var k = 2;
    var candidate = '$w-$k';
    while (taken.contains(candidate)) {
      candidate = '$w-${++k}';
    }
    return taken.contains(w) ? candidate : w;
  }

  // ── Addresses (spec 3d, RFC 5737 / 3849 / 2606) ───────────────────

  static final RegExp _ipv4 =
      RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  static final RegExp _ipv6 =
      RegExp(r'^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(?:%[A-Za-z0-9._-]+)?$');
  static final RegExp _port = RegExp(r'^:\d{1,5}$');

  /// An IPv6 literal (with or without a zone id), as opposed to a time or a
  /// MAC-less colon-separated token: at least a `::` or three colons, and
  /// only hex digits and colons.
  static bool _looksIpv6(String s) {
    final core = s.split('%').first;
    if (!_ipv6.hasMatch(core)) return false;
    if (!RegExp(r'[0-9A-Fa-f]').hasMatch(core)) return false;
    return core.contains('::') || ':'.allMatches(core).length >= 3;
  }

  /// A host address (IPv4, IPv6 or DNS name, optionally `host:port`, an IPv6
  /// optionally bracketed as `[addr]:port`) to a stable fake in a
  /// documentation range, so a reader can always tell a generated address
  /// from a real one and it can never collide with a live host. Preserves a
  /// trailing `:port` and the brackets.
  static String address(String real) {
    final value = real.trim();
    if (value.isEmpty) return real;

    // `[2001:db8::1]:22`: the brackets say where the address ends.
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close > 1) {
        final inner = value.substring(1, close);
        final rest = value.substring(close + 1);
        final port = _port.hasMatch(rest) ? rest : '';
        return '[${_looksIpv6(inner) ? _fakeIpv6(inner) : _fakeHostname(inner)}]$port';
      }
    }

    // Split off a :port suffix so it survives (people expect to see a port).
    // Only host:port when there is exactly one colon and digits after it, so
    // an IPv6 literal (many colons) is never split.
    String host = value;
    String portSuffix = '';
    final colon = value.lastIndexOf(':');
    if (colon > 0 &&
        colon == value.indexOf(':') &&
        RegExp(r'^\d{1,5}$').hasMatch(value.substring(colon + 1))) {
      host = value.substring(0, colon);
      portSuffix = value.substring(colon);
    }

    final String fake;
    if (_ipv4.hasMatch(host)) {
      fake = _fakeIpv4(host);
    } else if (host.contains(':') && _looksIpv6(host)) {
      fake = _fakeIpv6(host);
    } else {
      fake = _fakeHostname(host);
    }
    return '$fake$portSuffix';
  }

  /// RFC 5737 TEST-NET-1: `192.0.2.1` .. `192.0.2.254`.
  static String _fakeIpv4(String real) => '192.0.2.${(_hash(real) % 254) + 1}';

  /// RFC 3849 documentation prefix: `2001:db8::1` .. `2001:db8::ffff`. The
  /// zone id (`%eth0`) is dropped: it names an interface on the viewer's
  /// machine and is never part of the fake.
  static String _fakeIpv6(String real) =>
      '2001:db8::${((_hash(real.split('%').first) % 0xfffe) + 1).toRadixString(16)}';

  /// RFC 2606 reserved TLD: `host-NN.example.invalid`.
  static String _fakeHostname(String real) =>
      'host-${_nn(real)}.example.invalid';

  // ── Usernames, key names ──────────────────────────────────────────

  /// A login username to a stable generic token (`user42`). Reads as
  /// obviously synthetic, which is the point.
  static String username(String real) {
    final value = real.trim();
    if (value.isEmpty) return real;
    return 'user${_nn(value)}';
  }

  /// A key / identity display name to `key-NN`.
  static String keyName(String real) {
    final value = real.trim();
    if (value.isEmpty) return real;
    return 'key-${_nn(value)}';
  }

  // ── Fingerprints ──────────────────────────────────────────────────

  /// The fixed fake for a SHA256 fingerprint: exactly the length of a real
  /// one (44 base64 characters, so nothing reflows) and it decodes to
  /// `REDACTED-BY-ZESTSSH-REC-MODE`, so anyone who checks sees what it is.
  static final String fakeSha256 = 'SHA256:${base64.encode([
        ...utf8.encode('REDACTED-BY-ZESTSSH-REC-MODE'),
        ...List<int>.filled(4, 0),
      ])}';

  static final RegExp _fingerprintPrefix =
      RegExp(r'^(MD5|SHA1|SHA256|SHA512):', caseSensitive: false);

  /// A key fingerprint to the fixed fake. The digest is not a secret, but it
  /// identifies a key, so recording mode hides it. Keeps a known algorithm
  /// prefix so the value still reads as a fingerprint; anything else (a
  /// bare `ab:cd:...` hex string, whose first pair is part of the digest) is
  /// bullets throughout.
  static String fingerprint(String real) {
    final value = real.trim();
    if (value.isEmpty) return real;
    final m = _fingerprintPrefix.firstMatch(value);
    final algorithm = m?.group(1)?.toUpperCase();
    if (algorithm == 'SHA256') return fakeSha256;
    final prefix = algorithm == null ? '' : '$algorithm:';
    return '$prefix${'•' * 24}';
  }

  // ── Paths ─────────────────────────────────────────────────────────

  /// A filesystem path to a masked form. Separators, and at the layout level the
  /// segment count, are kept so the path still reads as a path, but every
  /// segment's characters are replaced so the OS username and directory names
  /// never render in a screenshot. Leading `/`, `~`, `.` and `..` are preserved.
  static String path(String real) => instance._path(real);

  String _path(String real) {
    final value = real.trim();
    if (value.isEmpty) return real;
    final parts = value.split('/');
    final out = StringBuffer();
    for (var idx = 0; idx < parts.length; idx++) {
      if (idx > 0) out.write('/');
      final p = parts[idx];
      if (p.isEmpty || p == '~' || p == '.' || p == '..') {
        out.write(p);
      } else {
        out.write(level == RedactLevel.strict
            ? _strictWord(p, const <String>{})
            : _pathSegLayout(p));
      }
    }
    return out.toString();
  }

  /// A layout-level segment mask: first and last char around bullets, so the
  /// exact name and length are hidden but the path still reads as a path.
  static String _pathSegLayout(String seg) {
    if (seg.length <= 2) return '••';
    return '${seg[0]}••${seg[seg.length - 1]}';
  }

  // ── Commands ──────────────────────────────────────────────────────

  /// The stand-in pool for Command history under recording mode: everyday
  /// commands that name nothing (any address is documentation range). One
  /// entry says outright what is going on, so a viewer is not misled.
  static const List<String> fakeCommands = [
    'sudo echo "obfuscated commands for recording mode"',
    "lsblk | grep 'nvme'",
    'cd ..',
    'ls -la',
    'git status',
    'df -h',
    'free -m',
    'uptime',
    'htop',
    'cat /etc/os-release',
    'systemctl status nginx',
    'docker ps',
    'tail -n 50 /var/log/syslog',
    'journalctl -u ssh --since today',
    'ping -c 3 192.0.2.10',
    'sudo apt update',
    'grep -rn "TODO" src/',
    'du -sh *',
    'ps aux | grep node',
    'make build',
    'whoami',
    'pwd',
    'nano README.md',
    'git pull',
  ];

  /// A real command to a harmless stand-in from [fakeCommands], picked by
  /// hash so the same command reads the same everywhere (and repeats still
  /// collapse). A command may embed hosts, paths and secrets in any shape a
  /// scan could miss, so it is replaced whole at both levels.
  static String command(String real) {
    if (real.trim().isEmpty) return real;
    return fakeCommands[_hash(real.trim()) % fakeCommands.length];
  }

  // ── Free text ─────────────────────────────────────────────────────

  static const String _localSuffixes =
      r'local|lan|home|internal|localdomain|arpa|intranet|corp';

  // Credentials inside a URL: `scheme://user:pass@host`. Both go, before the
  // scan below sees the `@` (a password is never something to keep).
  static final RegExp _urlCredentials =
      RegExp(r'(://)([^/\s:@\[\]]+):([^/\s@]*)@');

  static final RegExp _lineRe = RegExp(
    r'(?<![A-Za-z0-9._%+-])(?:'
    // user@host: everything up to the LAST @ is the user part (so `a@b@c`
    // is masked whole); the host may be a bracketed IPv6, an IP, a DNS name
    // or host:port, with underscores allowed.
    r'([A-Za-z0-9._+-]+(?:@[A-Za-z0-9._+-]+)*)@(\[[0-9A-Za-z:.%_-]+\](?::\d{1,5})?|[A-Za-z0-9._:-]+)'
    // or a standalone IPv4
    r'|((?:\d{1,3}\.){3}\d{1,3})'
    // or a dotted DNS name with at least two dots (prod.db.local)
    r'|((?:[A-Za-z0-9_-]+\.){2,}[A-Za-z]{2,})'
    // or a single-dot name under a local suffix (db-primary.local, nas.home)
    r'|([A-Za-z0-9_-]+\.(?:'
    '$_localSuffixes'
    r')(?![A-Za-z0-9]))'
    // or a single-dot name that carries a port (nas.home:22)
    r'|([A-Za-z0-9_-]+\.[A-Za-z][A-Za-z0-9_-]*(?=:\d{1,5}(?![A-Za-z0-9.])))'
    r')',
  );

  // A colon-separated token that may be an IPv6 literal (validated by
  // [_looksIpv6] so a clock time or a version never matches), optionally
  // bracketed and followed by a port.
  static final RegExp _ipv6Re = RegExp(
    r'(?<![A-Za-z0-9:.])(\[?)((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:%[A-Za-z0-9._-]+)?)(\]?)((?::\d{1,5})?)(?![A-Za-z0-9:])',
  );

  /// Redact a composed display string in one pass: `user@host` becomes
  /// `userNN@<fake host>`, a standalone IPv4, IPv6 or dotted DNS name becomes
  /// a documentation-range fake, credentials inside a URL are removed, and
  /// any REGISTERED host name or address embedded in the text is masked by
  /// its own rule (names case-insensitively). A substituted fake is never
  /// re-substituted, so the scan is idempotent.
  static String line(String text) => instance._line(text);

  // Already-synthetic forms, so a value masked at its source and then passed
  // through a free-text scan is not masked twice (idempotent).
  static final RegExp _fakeUser = RegExp(r'^user\d\d$');
  static final RegExp _sentenceEnd = RegExp(r'[.:]+$');
  static bool _isFakeHost(String h) {
    final bare = h.replaceAll('[', '').replaceAll(']', '');
    return bare.startsWith('192.0.2.') ||
        bare.startsWith('2001:db8::') ||
        bare.contains('.example.invalid');
  }

  String _line(String text) {
    if (text.isEmpty) return text;
    var out = text.replaceAllMapped(_urlCredentials, (m) {
      return '${m[1]}${username(m[2]!)}:$passwordMask@';
    });
    out = out.replaceAllMapped(_lineRe, (m) {
      if (m[1] != null) {
        if (_fakeUser.hasMatch(m[1]!) && _isFakeHost(m[2]!)) return m[0]!;
        // A name of the SSH protocol (chacha20-poly1305@openssh.com) is no
        // user at a host, and names nobody: it stays, with the full stop or
        // the colon of its sentence, which the scan takes for the host's.
        if (sshNamesWithAnAtSign.contains(m[0]!.replaceFirst(_sentenceEnd, ''))) return m[0]!;
        return '${username(m[1]!)}@${address(m[2]!)}';
      }
      if (m[3] != null) {
        return _isFakeHost(m[3]!) ? m[0]! : _fakeIpv4(m[3]!);
      }
      final host = m[4] ?? m[5] ?? m[6]!;
      return _isFakeHost(host) ? m[0]! : _fakeHostname(host);
    });
    out = out.replaceAllMapped(_ipv6Re, (m) {
      final core = m[2]!;
      if (!_looksIpv6(core) || _isFakeHost(core)) return m[0]!;
      final open = m[1]!;
      final close = m[3]!;
      if (open.isEmpty != close.isEmpty) return m[0]!; // half a bracket pair
      return '$open${_fakeIpv6(core)}$close${m[4]}';
    });
    if (_addresses.isNotEmpty) {
      final sorted = _addresses.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final a in sorted) {
        if (_isFakeHost(a) || !out.toLowerCase().contains(a.toLowerCase())) {
          continue;
        }
        final re = RegExp('(?<![A-Za-z0-9.])${RegExp.escape(a)}(?![A-Za-z0-9.])',
            caseSensitive: false);
        out = out.replaceAll(re, address(a));
      }
    }
    if (_names.isNotEmpty) {
      // Longest first so "db-primary" is masked before "db" could be.
      final sorted = _names.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      final lower = out.toLowerCase();
      for (final n in sorted) {
        if (!lower.contains(n.toLowerCase())) continue;
        final re = RegExp('(?<![A-Za-z0-9])${RegExp.escape(n)}(?![A-Za-z0-9])',
            caseSensitive: false);
        out = out.replaceAll(re, _name(n));
      }
    }
    return out;
  }
}
